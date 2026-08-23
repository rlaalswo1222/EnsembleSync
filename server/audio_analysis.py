from fastapi import APIRouter, Request
import psycopg2.extras
import disk
import ratelimit
from database import get_db
from celery_app import celery_app
from config import REDIS_HOST, REDIS_PORT
import uuid
import json
import redis

router = APIRouter()
redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, decode_responses=True)


def publish_room_event(room_id: str, message: dict):
    try:
        redis_client.publish(f"room_{room_id}", json.dumps(message))
    except Exception:
        pass

@router.post("/api/analysis/{room_id}/start")
async def start_analysis(
    http: Request, room_id: str, audio_file_id: str, job_type: str
):
    """
    분석 작업 생성 API
    - UC-06, UC-10, UC-12
    - job_type: bpm / pitch / separation (sync 제거)
    - 상태: pending → processing → done → failed
    """
    # 분리는 4분 곡에 6분 30초가 걸린다. 한 사람이 큐를 독차지하지 못하게
    # 막는다. BPM 은 몇 초라 굳이 세지 않는다.
    if job_type == "separation":
        limited = (
            ratelimit.limit_ip(http, "separate", *ratelimit.SEPARATE_PER_IP)
            or ratelimit.limit_room(
                room_id, "separate", *ratelimit.SEPARATE_PER_ROOM
            )
        )
        if limited:
            return limited

        # 6분을 돌린 끝에 공간이 없어 실패하는 것보다 지금 알려주는 편이
        # 낫다. 사용자는 이유를 알 수 있어야 한다.
        full = disk.guard_analyze()
        if full:
            return full

    conn = None
    try:
        # 같은 방에서 이미 돌고 있으면 새로 걸지 않는다.
        #
        # 두 번 눌렀거나 앱이 재시도를 잘못 돌린 경우가 대부분이다. 그대로
        # 받으면 큐만 늘고, 어차피 앱은 마지막 결과 하나만 보여준다.
        if job_type == "separation":
            conn = get_db()
            cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
            cur.execute(
                """
                SELECT id::text FROM analysis_job
                WHERE room_id = %s AND job_type = 'separation'
                  AND status IN ('pending', 'processing')
                ORDER BY requested_at LIMIT 1
                """,
                (room_id,),
            )
            running = cur.fetchone()
            cur.close()
            conn.close()
            conn = None
            if running:
                return {
                    "status": 409,
                    "job_id": running["id"],
                    "message": "이미 분석이 진행 중입니다.",
                }

        ALLOWED_JOB_TYPES = {'bpm', 'pitch', 'separation'}
        if job_type not in ALLOWED_JOB_TYPES:
            return {
                "status": 400,
                "message": f"지원하지 않는 job_type입니다. 허용 값: {', '.join(ALLOWED_JOB_TYPES)}"
            }

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # 1. audio_file 존재 여부 검증
        cur.execute(
            "SELECT id, file_type FROM audio_file WHERE id = %s AND room_id = %s",
            (audio_file_id, room_id),
        )
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
            file_path = f"uploads/audio/{room_id}/{audio_file_id}.{audio_file['file_type']}"
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

        publish_room_event(room_id, {
            "type": "analysis_started",
            "payload": {
                "room_id": room_id,
                "job_id": job_id,
                "job_type": job_type,
                "audio_file_id": audio_file_id,
            },
        })

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
        if job['status'] in ('done', 'failed', 'cancelled'):
            return {"status": 400, "message": f"취소할 수 없는 상태입니다: {job['status']}"}

        celery_task_id = job['celery_task_id']
        if celery_task_id:
            celery_app.control.revoke(celery_task_id, terminate=True, signal='SIGKILL')

        cur.execute(
            "UPDATE analysis_job SET status = 'cancelled' WHERE id = %s",
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

# 처리 시간 표본이 이만큼은 있어야 평균을 믿는다.
MIN_SAMPLES = 3

# 표본이 모자랄 때 쓸 값.
#
# 2 OCPU 에서 3분 20초 곡이 302초 걸렸다(htdemucs, 동시 실행 1개).
# 오디오 1초에 약 1.5초이므로 4분 곡이면 360초쯤 된다. 넉넉하게 잡는다 —
# 예상보다 일찍 끝나는 것은 괜찮지만 늦게 끝나면 고장으로 보인다.
FALLBACK_SECONDS = 400


def _avg_seconds(cur) -> float:
    """최근 분리 작업이 실제로 돈 시간의 평균.

    requested_at 이 아니라 started_at 부터 잰다. 큐에서 기다린 시간까지
    포함하면 대기가 길수록 예상 시간이 부풀어 오르고, 그 값으로 다시 대기
    시간을 계산하니 점점 커진다.
    """
    cur.execute(
        """
        SELECT avg(EXTRACT(EPOCH FROM (completed_at - started_at))) AS sec,
               count(*) AS n
        FROM (
            SELECT completed_at, started_at FROM analysis_job
            WHERE job_type = 'separation' AND status = 'done'
              AND started_at IS NOT NULL AND completed_at IS NOT NULL
            ORDER BY completed_at DESC LIMIT 20
        ) recent
        """
    )
    row = cur.fetchone()
    if not row or not row["n"] or row["n"] < MIN_SAMPLES or not row["sec"]:
        return FALLBACK_SECONDS
    return float(row["sec"])


def _queue_info(cur, job) -> dict:
    """내 앞에 몇 개가 남았는지와 대략 얼마나 걸릴지."""
    if job["job_type"] != "separation" or job["status"] not in (
        "pending",
        "processing",
    ):
        return {}

    avg = _avg_seconds(cur)

    if job["status"] == "processing":
        cur.execute(
            "SELECT EXTRACT(EPOCH FROM (now() - started_at)) AS sec "
            "FROM analysis_job WHERE id = %s",
            (job["id"],),
        )
        elapsed = float((cur.fetchone() or {}).get("sec") or 0)
        return {
            "queue_position": 0,
            "eta_seconds": max(0, int(avg - elapsed)),
        }

    # 내 앞에 있는 것 — 지금 도는 것과, 나보다 먼저 요청된 대기 건.
    cur.execute(
        """
        SELECT
          count(*) FILTER (WHERE status = 'processing') AS running,
          count(*) FILTER (
            WHERE status = 'pending' AND requested_at < %s
          ) AS waiting,
          max(started_at) FILTER (WHERE status = 'processing') AS started
        FROM analysis_job
        WHERE job_type = 'separation' AND status IN ('pending', 'processing')
        """,
        (job["requested_at"],),
    )
    row = cur.fetchone() or {}
    running = int(row.get("running") or 0)
    waiting = int(row.get("waiting") or 0)

    remaining = avg
    if running and row.get("started"):
        cur.execute(
            "SELECT EXTRACT(EPOCH FROM (now() - %s)) AS sec", (row["started"],)
        )
        elapsed = float((cur.fetchone() or {}).get("sec") or 0)
        remaining = max(0, avg - elapsed)

    return {
        "queue_position": running + waiting,
        "eta_seconds": int(remaining + waiting * avg) if running else
                       int(waiting * avg),
    }


@router.get("/api/analysis/{job_id}/status")
async def get_analysis_status(job_id: str):
    """분석 작업 상태와 대기 순번.

    서버는 한 번에 한 곡만 돌린다. 그래서 몇 분이 걸릴지는 내 곡의 길이가
    아니라 앞에 몇 명이 있느냐로 정해진다. 그것을 알려주지 않으면 사용자는
    진행률 0% 를 보며 고장 났다고 생각한다.
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT id, job_type, status, requested_at, completed_at, "
            "started_at FROM analysis_job WHERE id = %s",
            (job_id,)
        )
        job = cur.fetchone()
        if not job:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}

        queue = _queue_info(cur, job)
        cur.close()
        return {
            "status": 200,
            "job_id": str(job['id']),
            "job_type": job['job_type'],
            "job_status": job['status'],
            "requested_at": str(job['requested_at']),
            "completed_at": str(job['completed_at']) if job['completed_at'] else None,
            **queue,
        }
    except Exception as e:
        return {"status": 500, "message": f"상태 조회 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()
