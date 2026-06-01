import os
import sys
import shutil
import tempfile
import subprocess
from pathlib import Path
import re
import json
import redis
from database import get_db
from celery_app import celery_app

# Redis 클라이언트 (pub/sub용)
redis_client = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)

@celery_app.task(bind=True, name="separate_audio_task")
def separate_audio_task(self, file_path: str, room_id: str, job_id: str):
    tmp_dir = None
    # 임시 출력 폴더 (EC2 절대 경로 확정 전까지 로컬에 임시 저장)
    output_base_dir = os.path.join(os.getcwd(), "uploads", "separated", job_id)
    os.makedirs(output_base_dir, exist_ok=True)

    try:
        original = Path(file_path)
        tmp_dir = tempfile.mkdtemp()
        input_path = ""

        if original.suffix.lower() in ['.mp3', '.m4a', '.aac', '.ogg', '.flac']:
            wav_path = os.path.join(tmp_dir, original.stem + '.wav')

            convert = subprocess.run(
                ['ffmpeg', '-y', '-i', str(original), wav_path],
                capture_output=True, text=True
            )

            if convert.returncode != 0:
                input_path = str(original)
            else:
                input_path = wav_path
        else:
            input_path = str(original)


        cmd = [
            sys.executable, "-m", "demucs",
            "--name", "htdemucs",
            "--out", output_base_dir,
            input_path
        ]

        # Popen을 사용하여 실시간으로 로그(출력)를 한 줄씩 읽어옵니다.
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

        # Demucs의 터미널 출력을 한 줄씩 파싱하여 진행률(%)을 뽑아냅니다.
        for line in process.stdout:
            if '%' in line:
                # ' 45%|###   |' 같은 문자열에서 숫자만 쏙 뽑아내는 정규식
                match = re.search(r'(\d+)%', line)
                if match:
                    percent = int(match.group(1))

                    # Redis로 해당 방(room) 채널에 진행률 알림 쏘기
                    progress_msg = {
                        "type": "separation_progress",
                        "job_id": job_id,
                        "room_id": room_id,
                        "progress": percent
                    }
                    redis_client.publish(f"room_{room_id}", json.dumps(progress_msg))

        # 프로세스가 완전히 끝날 때까지 대기
        process.wait()

        if process.returncode != 0:
            raise Exception("Demucs 분리 중 오류 발생")

        stem_name = Path(input_path).stem
        demucs_out = Path(output_base_dir) / "htdemucs" / stem_name
        for track_name in ["vocals", "drums", "bass", "other"]:
            if not (demucs_out / f"{track_name}.wav").exists():
                raise Exception(f"Demucs 출력 파일 없음: {track_name}.wav")

        base_url = f"http://3.106.49.28:8000/uploads/separated/{job_id}/htdemucs/{stem_name}"
        tracks_dict = {
            "vocals": f"{base_url}/vocals.wav",
            "drums":  f"{base_url}/drums.wav",
            "bass":   f"{base_url}/bass.wav",
            "other":  f"{base_url}/other.wav",
        }

        conn = get_db()
        cur = conn.cursor()

        try:
            cur.execute(
                "UPDATE analysis_job SET status = 'done', completed_at = now() WHERE id = %s",
                (job_id,)
            )
            for track_type, file_url in tracks_dict.items():
                cur.execute(
                    "INSERT INTO separated_track (job_id, track_type, file_url) VALUES (%s, %s, %s)",
                    (job_id, track_type, file_url)
                )
            conn.commit()

        except Exception as db_error:
            conn.rollback()
            raise Exception(f"DB 저장 중 오류 발생: {db_error}")
        finally:
            cur.close()
            conn.close()

        complete_msg = {
            "type": "track_separated",
            "payload": {
                "room_id": room_id,
                "status": "completed",
                "tracks": tracks_dict,
                "message": "음원 분리가 완료되었습니다."
            }
        }
        redis_client.publish(f"room_{room_id}", json.dumps(complete_msg))

        return {"status": "success", "job_id": job_id, "message": "음원 분리 완벽 종료!"}

    except Exception as e:
        try:
            conn = get_db()
            cur = conn.cursor()
            cur.execute(
                "UPDATE analysis_job SET status = 'failed', completed_at = now() WHERE id = %s",
                (job_id,)
            )
            conn.commit()
            cur.close()
            conn.close()
        except Exception:
            pass
        return {"status": "error", "error_message": str(e)}

    finally:
        # 작업이 끝나면 성공/실패 여부와 상관없이 무조건 임시 폴더와 원본 파일을 깔끔하게 삭제합니다.
        if tmp_dir and os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)
        if os.path.exists(file_path):
            os.remove(file_path)
