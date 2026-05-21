# server/celery_worker.py
from celery import Celery
import os
import sys
import shutil
import tempfile
import subprocess
from pathlib import Path

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
        
        # Popen 대신 run을 사용하여 작업이 끝날 때까지 대기
        p = subprocess.run(cmd, capture_output=True, text=True)

        if p.returncode != 0:
            raise Exception(f"Demucs 분리 중 오류 발생: {p.stderr}")

        # TODO 4: EC2 저장 경로 이동 및 URL 생성 
        # TODO 5: separated_track DB 연동
        # TODO 6: WebSocket 완료 알림

        return {"status": "success", "job_id": job_id, "message": "음원 분리 완료"}

    except Exception as e:
        return {"status": "error", "error_message": str(e)}
        
    finally:
        # 메모리 확보를 위해 임시 폴더와 넘겨받은 원본 파일 삭제
        if tmp_dir and os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)
        if os.path.exists(file_path):
            os.remove(file_path)