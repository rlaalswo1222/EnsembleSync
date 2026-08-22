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
import track_analysis
from config import REDIS_HOST, REDIS_PORT, local_upload_path, public_url

# Redis 클라이언트 (pub/sub용)
redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, decode_responses=True)

# demucs 모델. htdemucs_6s 는 기본 4트랙에 기타와 피아노를 더해 6개를 낸다.
DEMUCS_MODEL = "htdemucs_6s"

STEM_NAMES = ["vocals", "drums", "bass", "guitar", "piano", "other"]

# 재생용 mp3 의 비트레이트. 분리 트랙은 원래 완벽한 음질이 아니라 192k 면 충분하다.
MP3_BITRATE = "192k"

# 새 곡을 분석하면 그 방의 이전 곡 결과를 지운다.
#
# 방 하나가 곡을 여러 개 들고 있으면 곡마다 300MB 씩 쌓인다. 사용자가
# 늘면 이게 디스크를 가장 빨리 채우는 경로가 된다. 앱도 마지막 결과만
# 보여주므로 이전 것은 화면에서 이미 닿을 수 없다.
#
# 끄고 싶으면 KEEP_PREVIOUS_SONGS=1 을 준다.
DISCARD_PREVIOUS = os.getenv("KEEP_PREVIOUS_SONGS", "0") != "1"


def _mark_processing(job_id: str):
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute(
            "UPDATE analysis_job SET status = 'processing' WHERE id = %s",
            (job_id,),
        )
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        # 상태 표시가 안 되어도 분리 자체는 진행한다.
        print(f"[job] processing 표시 실패: {e}")


def _discard_previous_songs(room_id: str, keep_job_id: str) -> int:
    """이 방의 이전 분석 결과를 지우고 지운 건수를 돌려준다.

    반드시 새 결과가 DB 에 저장된 뒤에 부른다. 먼저 지우면 새 분석이
    실패했을 때 이전 것까지 잃는다.

    끝난 작업(done)만 건드린다. 돌고 있는 작업의 폴더를 지우면 그 작업이
    쓰다 만 파일을 잃는다.

    원본 음원은 파일만 지우고 DB 레코드는 남긴다. analysis_job 이
    audio_file 을 참조하는데 ON DELETE CASCADE 가 없어서, 레코드를 지우려면
    작업 기록까지 먼저 지워야 한다. 무엇을 분석했었는지는 남겨 두는 편이
    낫고, 용량을 먹는 것은 어차피 파일이다.
    """
    removed = 0
    conn = get_db()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT DISTINCT aj.id::text, af.file_url
            FROM analysis_job aj
            JOIN audio_file af ON af.id = aj.audio_file_id
            WHERE aj.room_id = %s
              AND aj.job_type = 'separation'
              AND aj.status = 'done'
              AND aj.id <> %s
            """,
            (room_id, keep_job_id),
        )
        rows = cur.fetchall()
        if not rows:
            return 0

        old_ids = [r[0] for r in rows]

        for old_id, _ in rows:
            path = os.path.join(os.getcwd(), "uploads", "separated", old_id)
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
                removed += 1

        # 파일이 없어졌으니 레코드도 지운다. 남기면 앱에서 404 가 난다.
        cur.execute(
            "DELETE FROM separated_track WHERE job_id::text = ANY(%s)",
            (old_ids,),
        )

        # 이전 곡의 원본. 지금 곡이 쓰는 파일은 건드리지 않는다.
        cur.execute(
            "SELECT file_url FROM audio_file WHERE id = ("
            "  SELECT audio_file_id FROM analysis_job WHERE id = %s)",
            (keep_job_id,),
        )
        keep_row = cur.fetchone()
        keep_url = keep_row[0] if keep_row else None

        for _, file_url in rows:
            if not file_url or file_url == keep_url:
                continue
            try:
                path = local_upload_path(file_url)
                if os.path.exists(path):
                    os.remove(path)
            except Exception:
                pass

        conn.commit()
        return removed
    except Exception as e:
        conn.rollback()
        print(f"[discard] 이전 곡 정리 실패: {e}")
        return 0
    finally:
        cur.close()
        conn.close()


def _publish(room_id: str, job_id: str, stage: str, message: str,
             progress: float = None):
    """진행 상황을 방에 알린다.

    분리는 수 분 걸리는데 화면에 "분리 중" 한 줄만 떠 있으면 멈춘 것인지
    도는 것인지 알 수 없다. 어느 단계인지 글로 내보낸다.
    """
    payload = {
        "type": "separation_stage",
        "job_id": job_id,
        "room_id": room_id,
        "stage": stage,
        "message": message,
    }
    if progress is not None:
        payload["progress"] = progress
    try:
        redis_client.publish(f"room_{room_id}", json.dumps(payload))
    except Exception:
        # 알림이 안 가도 작업 자체는 계속되어야 한다.
        pass


def _encode_mp3(demucs_out: Path) -> dict:
    """스템 wav 를 재생용 mp3 로 변환한다. {스템: 파일명} 을 돌려준다.

    demucs 가 내놓는 wav 는 4분 곡 기준 트랙당 40MB 라 4개를 받으면 160MB 다.
    SoLoud 는 스트리밍이 아니라 파일 전체를 메모리에 올려놓고 재생하므로,
    그대로 두면 재생 시작 전에 160MB 를 받아야 한다. mp3 로 7배 줄인다.

    원본 wav 는 지우지 않는다. 다운로드는 계속 무손실로 받게 한다.
    """
    procs = {}
    for name in STEM_NAMES:
        src = demucs_out / f"{name}.wav"
        if not src.exists():
            continue
        dst = demucs_out / f"{name}.mp3"
        # 4개는 서로 독립이라 동시에 돌린다. 순차 변환보다 눈에 띄게 빠르다.
        procs[name] = (dst, subprocess.Popen(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
             "-codec:a", "libmp3lame", "-b:a", MP3_BITRATE, str(dst)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ))

    encoded = {}
    for name, (dst, proc) in procs.items():
        try:
            if proc.wait(timeout=600) == 0 and dst.exists():
                encoded[name] = dst.name
        except Exception as e:
            proc.kill()
            print(f"[mp3] {name} 변환 실패: {e}")
    return encoded

@celery_app.task(bind=True, name="separate_audio_task")
def separate_audio_task(self, file_path: str, room_id: str, job_id: str):
    tmp_dir = None
    # 임시 출력 폴더 (EC2 절대 경로 확정 전까지 로컬에 임시 저장)
    output_base_dir = os.path.join(os.getcwd(), "uploads", "separated", job_id)
    os.makedirs(output_base_dir, exist_ok=True)

    try:
        # 큐에서 기다리는 것(pending)과 실제로 도는 것(processing)을 구분한다.
        # 이 구분이 없으면 정리 작업이 "오래 pending" 을 죽은 작업으로 보고
        # 큐에서 정직하게 기다리던 것까지 실패로 만든다.
        _mark_processing(job_id)

        original = Path(file_path)
        tmp_dir = tempfile.mkdtemp()
        input_path = ""

        _publish(room_id, job_id, "prepare", f"{original.name} 읽는 중")

        if original.suffix.lower() in ['.mp3', '.m4a', '.aac', '.ogg', '.flac']:
            wav_path = os.path.join(tmp_dir, original.stem + '.wav')

            _publish(room_id, job_id, "convert", "WAV 로 변환 중")
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

        _publish(
            room_id, job_id, "model",
            f"분리 모델 준비 중 ({len(STEM_NAMES)}개 트랙)",
        )

        cmd = [
            sys.executable, "-m", "demucs",
            "--name", DEMUCS_MODEL,
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
                    _publish(
                        room_id, job_id, "separate",
                        f"트랙 분리 중 {percent}%", progress=percent / 100.0,
                    )

        # 프로세스가 완전히 끝날 때까지 대기
        process.wait()

        if process.returncode != 0:
            raise Exception("Demucs 분리 중 오류 발생")

        stem_name = Path(input_path).stem
        demucs_out = Path(output_base_dir) / DEMUCS_MODEL / stem_name
        for track_name in STEM_NAMES:
            if not (demucs_out / f"{track_name}.wav").exists():
                raise Exception(f"Demucs 출력 파일 없음: {track_name}.wav")

        # 파형/키/코드 분석. 여기서 돌리는 이유는 ffmpeg 이 만든 WAV 와 스템이
        # 아직 디스크에 있어서 디코딩을 다시 안 해도 되기 때문이다.
        # 4분 곡 기준 8초 안팎 (워커가 막 뜬 첫 작업은 numba 컴파일로 더 걸린다).
        # 실패해도 분리 결과는 그대로 살린다. 부가 정보일 뿐이다.
        _publish(room_id, job_id, "analyze", "파형·키·코드 분석 중")

        analysis_ready = False
        try:
            track_analysis.analyze(
                mix_path=input_path,
                stem_paths={
                    t: str(demucs_out / f"{t}.wav")
                    for t in STEM_NAMES
                },
                out_path=os.path.join(output_base_dir, "analysis.json"),
            )
            analysis_ready = True
        except Exception as analysis_error:
            print(f"[track_analysis] 분석 실패 (분리는 정상): {analysis_error}")

        _publish(room_id, job_id, "encode", "재생용 mp3 만드는 중")

        # 재생용 mp3. 실패한 트랙은 그냥 wav 로 재생하게 둔다.
        mp3_names = {}
        try:
            mp3_names = _encode_mp3(demucs_out)
        except Exception as mp3_error:
            print(f"[mp3] 변환 건너뜀 (분리는 정상): {mp3_error}")

        _publish(room_id, job_id, "save", "결과 저장 중")

        # DB 에는 상대경로로 저장한다 (서버 주소가 바뀌어도 레코드 수정 불필요)
        base_path = f"/uploads/separated/{job_id}/{DEMUCS_MODEL}/{stem_name}"
        analysis_url = f"/uploads/separated/{job_id}/analysis.json"
        tracks_dict = {
            name: f"{base_path}/{name}.wav" for name in STEM_NAMES
        }

        # 재생에 쓸 주소. wav 는 다운로드용으로 그대로 남는다.
        streams_dict = {
            name: f"{base_path}/{filename}"
            for name, filename in mp3_names.items()
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

        # 새 결과가 안전하게 저장된 뒤에야 이전 것을 버린다.
        if DISCARD_PREVIOUS:
            discarded = _discard_previous_songs(room_id, job_id)
            if discarded:
                print(f"[discard] 이전 곡 {discarded}건 정리")

        complete_msg = {
            "type": "track_separated",
            "payload": {
                "room_id": room_id,
                "job_id": job_id,
                "status": "completed",
                # 클라이언트에는 완전한 주소로 내보낸다
                "tracks": {k: public_url(v) for k, v in tracks_dict.items()},
                "streams": {k: public_url(v) for k, v in streams_dict.items()},
                "analysis_url": public_url(analysis_url) if analysis_ready else None,
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
        # ffmpeg 변환용 임시 폴더만 정리한다.
        # 업로드된 원본 음원은 지우지 않는다. audio_file.file_url 이 이 파일을
        # 가리키고 있어서, 삭제하면 BPM 결과 화면의 재생이 404 가 된다.
        if tmp_dir and os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)
