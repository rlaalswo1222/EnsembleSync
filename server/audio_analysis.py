from fastapi import APIRouter
import psycopg2.extras
from database import get_db
from celery_app import celery_app
import uuid

router = APIRouter()

@router.post("/api/analysis/{room_id}/start")
async def start_analysis(room_id: str, audio_file_id: str, job_type: str):
    """
    분석 작업 생성 API
    - UC-06, UC-10, UC-12
    - job_type: bpm / pitch / separation (sync 제거)
    - 상태: pending → processing → done → failed
    """
    conn = None
    try:
        ALLOWED_JOB_TYPES = {'bpm', 'pitch', 'separation'}
        if job_type not in ALLOWED_JOB_TYPES:
            return {
                "status": 400,
                "message": f"지원하지 않는 job_type입니다. 허용 값: {', '.join(ALLOWED_JOB_TYPES)}"
            }

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # 1. audio_file 존재 여부 검증
        cur.execute("SELECT id FROM audio_file WHERE id = %s", (audio_file_id,))
        audio_file = cur.fetchone()
        if not audio_file:
            return {"status": 404, "message": "존재하지 않는 음원 파일입니다."}

        # 2. analysis_job 생성 (pending 상태)
        job_id = str(uuid.uuid4())
        cur.execute(
            """
            INSERT INTO analysis_job (id, audio_file_id, room_id, job_type, status, requested_at)
            VALUES (%s, %s, %s, %s, 'pending', now())
            """,
            (job_id, audio_file_id, room_id, job_type)
        )
        conn.commit()

        # 3. Celery 비동기 작업 등록
        if job_type == "separation":
            cur.execute("SELECT file_type FROM audio_file WHERE id = %s", (audio_file_id,))
            audio_row = cur.fetchone()
            file_path = f"uploads/audio/{room_id}/{audio_file_id}.{audio_row['file_type']}"
            task = celery_app.send_task(
                "separate_audio_task",
                args=[file_path, room_id, job_id],
                queue="separation",
            )
        else:
            queue_name = "bpm" if job_type == "bpm" else job_type
            task = celery_app.send_task(
                f"tasks.{job_type}_analysis",
                args=[job_id, audio_file_id],
                queue=queue_name,
            )

        # 4. celery_task_id 업데이트
        cur.execute(
            "UPDATE analysis_job SET celery_task_id = %s WHERE id = %s",
            (task.id, job_id)
        )
        conn.commit()
        cur.close()

        return {
            "status": 200,
            "job_id": job_id,
            "job_type": job_type,
            "status_message": "분석 작업이 시작되었습니다. (pending)",
            "message": "분석 완료 시 WebSocket으로 결과를 전달합니다."
        }
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"분석 작업 생성 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()

@router.post("/api/analysis/{job_id}/cancel")
async def cancel_analysis(job_id: str):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(
            "SELECT celery_task_id, status FROM analysis_job WHERE id = %s",
            (job_id,)
        )
        job = cur.fetchone()
        if not job:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}
        if job['status'] in ('done', 'failed'):
            return {"status": 200, "message": "이미 종료된 작업입니다."}

        celery_task_id = job['celery_task_id']
        if celery_task_id:
            celery_app.control.revoke(celery_task_id, terminate=True, signal='SIGKILL')

        cur.execute(
            "UPDATE analysis_job SET status = 'failed', completed_at = now() WHERE id = %s",
            (job_id,)
        )
        conn.commit()
        cur.close()

        return {"status": 200, "message": "작업이 취소되었습니다."}
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"취소 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()

@router.get("/api/analysis/{job_id}/status")
async def get_analysis_status(job_id: str):
    """
    분석 작업 상태 조회 API
    - pending / processing / done / failed
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT id, job_type, status, requested_at, completed_at FROM analysis_job WHERE id = %s",
            (job_id,)
        )
        job = cur.fetchone()
        if not job:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}

        cur.close()
        return {
            "status": 200,
            "job_id": str(job['id']),
            "job_type": job['job_type'],
            "job_status": job['status'],
            "requested_at": str(job['requested_at']),
            "completed_at": str(job['completed_at']) if job['completed_at'] else None
        }
    except Exception as e:
        return {"status": 500, "message": f"상태 조회 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()
