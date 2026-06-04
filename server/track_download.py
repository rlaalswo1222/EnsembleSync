from fastapi import APIRouter, UploadFile, File, Form
from fastapi.responses import FileResponse
import psycopg2.extras
from database import get_db
from celery_app import celery_app
import uuid
import shutil
import os

router = APIRouter()

ALLOWED_AUDIO_EXTENSIONS = {'mp3', 'wav', 'flac', 'm4a'}

@router.post("/api/track/separate")
async def request_track_separation(
    room_id: str = Form(...),
    file: UploadFile = File(...)
):
    conn = None
    file_path = None
    try:
        ext = file.filename.split('.')[-1].lower()
        if ext not in ALLOWED_AUDIO_EXTENSIONS:
            return {"status": 400, "message": f"지원하지 않는 오디오 형식입니다. 허용 형식: {', '.join(ALLOWED_AUDIO_EXTENSIONS)}"}

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute("SELECT id FROM room WHERE id = %s", (room_id,))
        if not cur.fetchone():
            return {"status": 404, "message": "존재하지 않는 방입니다."}

        audio_id = str(uuid.uuid4())
        save_dir = f"uploads/audio/{room_id}"
        os.makedirs(save_dir, exist_ok=True)
        file_path = f"{save_dir}/{audio_id}.{ext}"

        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)

        file_url = f"http://3.106.49.28:8000/uploads/audio/{room_id}/{audio_id}.{ext}"
        cur.execute(
            "INSERT INTO audio_file (id, room_id, file_type, file_url, purpose, uploaded_at) VALUES (%s, %s, %s, %s, 'separation', now())",
            (audio_id, room_id, ext, file_url)
        )

        job_id = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO analysis_job (id, audio_file_id, room_id, job_type, status, requested_at) VALUES (%s, %s, %s, 'separation', 'pending', now())",
            (job_id, audio_id, room_id)
        )
        conn.commit()

        task = celery_app.send_task(
            "separate_audio_task",
            args=[file_path, room_id, job_id],
            queue="separation",
        )
        cur.execute("UPDATE analysis_job SET celery_task_id = %s WHERE id = %s", (task.id, job_id))
        conn.commit()
        cur.close()

        return {
            "status": 202,
            "job_id": job_id,
            "message": "트랙 분리 작업이 백그라운드에서 시작되었습니다. 완료 시 실시간으로 알림을 보냅니다."
        }
    except Exception as e:
        if conn:
            conn.rollback()
        if file_path and os.path.exists(file_path):
            os.remove(file_path)
        return {"status": 500, "message": f"트랙 분리 요청 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()

@router.get("/api/track/{job_id}/list")
async def get_track_list(job_id: str):
    """
    분리 트랙 목록 조회 API
    - UC-13, FR-10
    - job_id로 분리된 4개 트랙 목록 반환
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # analysis_job 존재 여부 확인
        cur.execute("SELECT id, status FROM analysis_job WHERE id = %s", (job_id,))
        job = cur.fetchone()
        if not job:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}
        if job['status'] != 'done':
            return {
                "status": 400,
                "message": f"분리 작업이 아직 완료되지 않았습니다. 현재 상태: {job['status']}"
            }

        # 분리 트랙 목록 조회
        cur.execute(
            "SELECT id, track_type, file_url, created_at FROM separated_track WHERE job_id = %s",
            (job_id,)
        )
        tracks = cur.fetchall()
        cur.close()

        return {
            "status": 200,
            "job_id": job_id,
            "tracks": [
                {
                    "track_id": str(t['id']),
                    "track_type": t['track_type'],
                    "file_url": t['file_url'],
                    "created_at": str(t['created_at'])
                }
                for t in tracks
            ]
        }
    except Exception as e:
        return {"status": 500, "message": f"트랙 목록 조회 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()

@router.get("/api/track/{job_id}/download/{track_type}")
async def download_track(job_id: str, track_type: str):
    """
    분리 트랙 다운로드 API
    - UC-13, FR-10
    - track_type: vocals / drums / bass / guitar
    """
    conn = None
    try:
        ALLOWED_TRACK_TYPES = {'vocals', 'drums', 'bass', 'other'}
        if track_type not in ALLOWED_TRACK_TYPES:
            return {
                "status": 400,
                "message": f"지원하지 않는 트랙 타입입니다. 허용 값: {', '.join(ALLOWED_TRACK_TYPES)}"
            }

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT file_url FROM separated_track WHERE job_id = %s AND track_type = %s",
            (job_id, track_type)
        )
        track = cur.fetchone()
        cur.close()

        if not track:
            return {"status": 404, "message": "해당 트랙을 찾을 수 없습니다."}

        # 파일 경로 추출
        file_url = track['file_url']
        file_path = file_url.replace("http://3.106.49.28:8000/", "")

        if not os.path.exists(file_path):
            return {"status": 404, "message": "파일이 서버에 존재하지 않습니다."}

        return FileResponse(
            path=file_path,
            filename=f"{track_type}.wav",
            media_type="audio/wav"
        )
    except Exception as e:
        return {"status": 500, "message": f"트랙 다운로드 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()
