from fastapi import APIRouter, Request
import psycopg2.extras
import disk
import ratelimit
import room_auth
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
        conn = get_db()
        cur = conn.cursor()
        denied = room_auth.require(cur, http, room_id)
        cur.close()
        conn.close()
        conn = None
        if denied:
            return denied

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
async def cancel_analysis(http: Request, job_id: str):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # job_id 만으로 결과를 내주면 안 된다. 그 작업이 어느 방의 것인지
        # 찾아서 그 방 사람인지 확인한다.
        denied = room_auth.require(
            cur, http, room_auth.room_of_job(cur, job_id)
        )
        if denied:
            return denied

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

# 비율 표본이 이만큼은 있어야 믿는다.
MIN_SAMPLES = 3

# 오디오 1초를 처리하는 데 걸리는 초.
#
# 2 OCPU 에서 3분 20초(199.6초) 곡이 302.2초 걸렸다 — 1.51 이다.
# (htdemucs, 동시 실행 1개, demucs 가 코어 1.85개를 씀)
# 표본이 쌓이기 전까지 이 값을 쓴다.
FALLBACK_RATE = 1.55

# 비율이 이 범위를 벗어나면 표본이 이상한 것으로 보고 버린다.
#
# 서버가 잠깐 다른 일에 눌렸거나, 길이를 잘못 읽은 파일 하나가 섞이면
# 평균이 크게 흔들린다. 그 값으로 "약 3시간" 같은 소리를 하게 된다.
RATE_MIN, RATE_MAX = 0.5, 6.0

# 길이를 모르는 곡에 가정하는 값. 예전에 올라온 것들은 duration_sec 이
# 비어 있다.
ASSUMED_DURATION = 240


def _rate(cur) -> float:
    """오디오 1초당 실제로 걸린 초.

    예전에는 "최근 작업들이 걸린 시간의 평균" 을 그대로 썼다. 곡 길이를
    보지 않았다는 뜻이다. 1분짜리를 올린 사람과 6분짜리를 올린 사람에게
    같은 숫자를 내놓았으니 맞을 리가 없었다.

    길이로 나눈 비율은 곡이 달라져도 거의 같다. 그래서 이쪽을 평균 낸다.

    requested_at 이 아니라 started_at 부터 잰다. 큐에서 기다린 시간까지
    넣으면 대기가 길수록 비율이 부풀고, 그 값으로 다시 대기 시간을
    계산하니 점점 커진다.

    duration_sec 이 있는 것만 센다. 그 값을 채우기 시작한 것이 동시 실행을
    1개로 줄인 시점과 같아서, 옛 기록(두 개가 겹쳐 돌아 두 배로 느렸던
    때)이 자연히 걸러진다.
    """
    cur.execute(
        """
        SELECT avg(rate) AS rate, count(*) AS n FROM (
            SELECT EXTRACT(EPOCH FROM (aj.completed_at - aj.started_at))
                   / af.duration_sec AS rate
            FROM analysis_job aj
            JOIN audio_file af ON af.id = aj.audio_file_id
            WHERE aj.job_type = 'separation' AND aj.status = 'done'
              AND aj.started_at IS NOT NULL AND aj.completed_at IS NOT NULL
              AND af.duration_sec IS NOT NULL AND af.duration_sec > 0
            ORDER BY aj.completed_at DESC LIMIT 20
        ) recent
        WHERE rate BETWEEN %s AND %s
        """,
        (RATE_MIN, RATE_MAX),
    )
    row = cur.fetchone()
    if not row or not row["n"] or row["n"] < MIN_SAMPLES or not row["rate"]:
        return FALLBACK_RATE
    return float(row["rate"])


def _durations(cur, job_ids) -> dict:
    """작업 id → 곡 길이(초)."""
    if not job_ids:
        return {}
    cur.execute(
        """
        SELECT aj.id::text AS job_id, af.duration_sec
        FROM analysis_job aj
        JOIN audio_file af ON af.id = aj.audio_file_id
        WHERE aj.id::text = ANY(%s)
        """,
        (list(job_ids),),
    )
    return {
        r["job_id"]: (r["duration_sec"] or ASSUMED_DURATION)
        for r in cur.fetchall()
    }


# 분리를 동시에 몇 개까지 돌리는가. compose 의 --concurrency 와 같아야 한다.
#
# demucs 는 혼자서도 코어를 거의 다 쓴다(2 OCPU 에서 1.85개). 그래서 하나만
# 돌린다. 여기서는 "진짜로 도는 것이 최대 몇 개인가" 를 아는 데 쓴다.
SEPARATION_SLOTS = 1


def _queue_info(cur, job) -> dict:
    """내 앞에 몇 개가 남았는지와 대략 얼마나 걸릴지.

    앞선 곡들의 길이를 하나씩 더한다. 예전에는 "평균 × 개수" 였는데, 앞에
    1분짜리가 있는 경우와 6분짜리가 있는 경우가 같은 값으로 나왔다.
    """
    if job["job_type"] != "separation" or job["status"] not in (
        "pending",
        "processing",
    ):
        return {}

    rate = _rate(cur)
    my_id = str(job["id"])

    if job["status"] == "processing":
        cur.execute(
            """
            SELECT EXTRACT(EPOCH FROM (now() - aj.started_at)) AS sec,
                   af.duration_sec
            FROM analysis_job aj
            JOIN audio_file af ON af.id = aj.audio_file_id
            WHERE aj.id = %s
            """,
            (my_id,),
        )
        row = cur.fetchone() or {}
        elapsed = float(row.get("sec") or 0)
        total = (row.get("duration_sec") or ASSUMED_DURATION) * rate
        return {
            "queue_position": 0,
            "eta_seconds": max(0, int(total - elapsed)),
            "own_seconds": int(total),
        }

    # 내 앞에 있는 것 — 지금 도는 것과, 나보다 먼저 요청된 대기 건.
    cur.execute(
        """
        SELECT id::text, status, started_at
        FROM analysis_job
        WHERE job_type = 'separation'
          AND (status = 'processing'
               OR (status = 'pending' AND requested_at < %s))
        ORDER BY started_at DESC NULLS LAST
        """,
        (job["requested_at"],),
    )
    rows = cur.fetchall()

    # 진짜로 도는 것은 아무리 많아도 슬롯 수만큼이다.
    #
    # processing 으로 남은 행이 그보다 많다면 죽은 작업이다. 워커가 일을
    # 하다 재시작되면(배포가 대표적이다) 프로세스는 사라지는데 DB 의
    # 상태는 그대로 남는다. 그걸 세면 "앞에 2개" 같은 거짓말을 하게 된다.
    #
    # 가장 나중에 시작한 것을 살아 있는 것으로 본다. 슬롯이 하나면 새
    # 작업은 앞 것이 비워진 뒤에야 시작하기 때문이다.
    processing = [r for r in rows if r["status"] == "processing"]
    live = processing[:SEPARATION_SLOTS]
    waiting = [r for r in rows if r["status"] == "pending"]

    ahead = live + waiting
    lengths = _durations(cur, [r["id"] for r in ahead] + [my_id])

    eta = 0.0
    for r in live:
        total = lengths.get(r["id"], ASSUMED_DURATION) * rate
        cur.execute(
            "SELECT EXTRACT(EPOCH FROM (now() - %s)) AS sec", (r["started_at"],)
        )
        elapsed = float((cur.fetchone() or {}).get("sec") or 0)
        eta += max(0.0, total - elapsed)
    for r in waiting:
        eta += lengths.get(r["id"], ASSUMED_DURATION) * rate

    # 내 곡을 도는 데 걸리는 시간.
    own = lengths.get(my_id, ASSUMED_DURATION) * rate

    return {
        "queue_position": len(ahead),
        # '내 차례가 올 때까지' 가 아니라 '내 것이 끝날 때까지' 다.
        #
        # 예전에는 대기 중일 때 앞사람 몫만 셌다. 그래서 내 차례가 되는
        # 순간 숫자가 줄다 말고 다시 튀어 올랐다. 기다리는 사람이 알고
        # 싶은 것은 결과를 언제 보느냐이지 언제 시작하느냐가 아니다.
        "eta_seconds": int(eta + own),
        "own_seconds": int(own),
    }


@router.get("/api/analysis/{job_id}/status")
async def get_analysis_status(http: Request, job_id: str):
    """분석 작업 상태와 대기 순번.

    서버는 한 번에 한 곡만 돌린다. 그래서 몇 분이 걸릴지는 내 곡의 길이가
    아니라 앞에 몇 명이 있느냐로 정해진다. 그것을 알려주지 않으면 사용자는
    진행률 0% 를 보며 고장 났다고 생각한다.
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # job_id 만으로 결과를 내주면 안 된다. 그 작업이 어느 방의 것인지
        # 찾아서 그 방 사람인지 확인한다.
        denied = room_auth.require(
            cur, http, room_auth.room_of_job(cur, job_id)
        )
        if denied:
            return denied

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
