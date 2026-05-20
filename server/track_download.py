from fastapi import APIRouter
from fastapi.responses import FileResponse
import psycopg2.extras
from database import get_db
import os

router = APIRouter()

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
        ALLOWED_TRACK_TYPES = {'vocals', 'drums', 'bass', 'guitar'}
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
        file_path = file_url.replace("http://3.25.160.93:8000/", "")

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