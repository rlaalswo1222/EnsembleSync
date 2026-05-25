from fastapi import APIRouter
import psycopg2.extras
from database import get_db

router = APIRouter()

@router.get("/api/bpm/{job_id}/result")
async def get_bpm_result(job_id: str):
    """
    BPM 분석 결과 반환 API
    - UC-07, FR-04, FR-05
    - BPM 수치, 곡선 데이터, 변화 구간 반환
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # 1. analysis_job 존재 여부 및 상태 확인
        cur.execute(
            "SELECT id, status, job_type FROM analysis_job WHERE id = %s",
            (job_id,)
        )
        job = cur.fetchone()
        if not job:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}
        if job['job_type'] != 'bpm':
            return {"status": 400, "message": "BPM 분석 작업이 아닙니다."}
        if job['status'] != 'done':
            return {
                "status": 400,
                "message": f"BPM 분석이 아직 완료되지 않았습니다. 현재 상태: {job['status']}"
            }

        # 2. bpm_result 조회
        cur.execute(
            "SELECT id, job_id, bpm_data, base_bpm, deviation_sections FROM bpm_result WHERE job_id = %s",
            (job_id,)
        )
        result = cur.fetchone()
        if not result:
            return {"status": 404, "message": "BPM 분석 결과가 없습니다."}

        cur.close()

        return {
            "status": 200,
            "job_id": job_id,
            "bpm_data": result['bpm_data'],          # 구간별 BPM 곡선 [{time, bpm}]
            "base_bpm": result['base_bpm'],           # 기준 BPM 수치
            "deviation_sections": result['deviation_sections'],  # 이탈 구간 [{start, end, bpm}]
            "message": "BPM 분석 결과를 반환합니다."
        }
    except Exception as e:
        return {"status": 500, "message": f"BPM 결과 조회 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()