from celery import Celery
import os
import sys
import shutil
import tempfile
import subprocess
from pathlib import Path
import re
import json
import redis
from database import get_db  # 맨 위에 한 번만 선언!

# Redis 클라이언트 세팅 (Celery와 동일한 Redis 사용)
redis_client = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)

# 1. Celery 앱 생성 (Redis 브로커 연결)
celery_app = Celery(
    "ensemble_tasks",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/0"
)

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

        # ==========================================
        # [TODO 2: FFmpeg 파일 변환 처리]
        # ==========================================
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


        # ==========================================
        # [TODO 3: Demucs 트랙 분리 실행]
        # ==========================================
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
                        "type": "SEPARATION_PROGRESS",
                        "job_id": job_id,
                        "room_id": room_id,
                        "progress": percent
                    }
                    redis_client.publish(f"room_{room_id}", json.dumps(progress_msg))
                    
        # 프로세스가 완전히 끝날 때까지 대기
        process.wait()

        if process.returncode != 0:
            raise Exception("Demucs 분리 중 오류 발생")
        
        # ==========================================
        # [TODO 4: EC2 저장 경로 이동 및 URL 생성]
        # ==========================================
        server_ip = os.getenv("SERVER_URL", "http://127.0.0.1:8000")
        base_url = f"{server_ip}/static/separated/{job_id}"
        
        # ==========================================
        # [TODO 5: separated_track DB 연동]
        # ==========================================
        conn = get_db()
        cur = conn.cursor()
        
        try:
            update_job_query = "UPDATE analysis_job SET status = 'done', completed_at = now() WHERE id = %s;"
            cur.execute(update_job_query, (job_id,))

            insert_track_query = "INSERT INTO separated_track (job_id, track_type, file_url) VALUES (%s, %s, %s);"
            
            tracks = [
                {"type": "vocals", "url": f"{base_url}/vocals.wav"},
                {"type": "drums", "url": f"{base_url}/drums.wav"},
                {"type": "bass", "url": f"{base_url}/bass.wav"},
                {"type": "guitar", "url": f"{base_url}/guitar.wav"}
            ]

            for track in tracks:
                cur.execute(insert_track_query, (job_id, track["type"], track["url"]))

            conn.commit()

        except Exception as db_error:
            conn.rollback()
            raise Exception(f"DB 저장 중 오류 발생: {db_error}")
        finally:
            cur.close()
            conn.close()
            
        # ==========================================
        # [TODO 6: WebSocket 완료 알림]
        # ==========================================
        complete_msg = {
            "type": "SEPARATION_COMPLETED",
            "job_id": job_id,
            "room_id": room_id,
            "tracks": tracks
        }
        redis_client.publish(f"room_{room_id}", json.dumps(complete_msg))

        return {"status": "success", "job_id": job_id, "message": "음원 분리 완벽 종료!"}

    # ★★★ 복구된 부분: 메인 try 블록에 대한 예외 처리 및 파일 청소 ★★★
    except Exception as e:
        # 실패 시 에러 메시지 반환
        return {"status": "error", "error_message": str(e)}
        
    finally:
        # 작업이 끝나면 성공/실패 여부와 상관없이 무조건 임시 폴더와 원본 파일을 깔끔하게 삭제합니다.
        if tmp_dir and os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)
        if os.path.exists(file_path):
            os.remove(file_path)