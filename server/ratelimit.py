"""요청 횟수 제한.

한 사람이 분리 요청을 천 번 던지면 큐가 막히고 디스크가 찬다. 악의가
없어도 앱이 재시도를 잘못 돌면 같은 일이 난다.

Redis 의 고정 창 방식이다. INCR 로 세고 창이 끝나면 키가 만료된다.
슬라이딩 창이 더 정확하지만, 여기서 막으려는 것은 "한 사람이 서버를
독차지하는 것" 이지 정밀한 계량이 아니다.

IP 로 세는 것에는 한계가 있다. 마음먹은 사람은 주소를 바꿔 가며 우회할 수
있고, 반대로 같은 공유기를 쓰는 사람들은 한 사람으로 묶인다. 그래도
실수와 가벼운 남용은 대부분 여기서 걸린다. 계정이 생기면 그때 사용자
단위로 옮기는 것이 맞다.
"""
import os

import redis
from fastapi import Request

from config import REDIS_HOST, REDIS_PORT

# 끄고 싶을 때. 부하 시험 같은 경우에 쓴다.
ENABLED = os.getenv("RATE_LIMIT_ENABLED", "1") == "1"

try:
    _redis = redis.Redis(
        host=REDIS_HOST, port=REDIS_PORT, db=2, decode_responses=True,
        socket_connect_timeout=1, socket_timeout=1,
    )
    _redis.ping()
except Exception:
    _redis = None


def client_ip(request: Request) -> str:
    """Caddy 뒤에 있으므로 X-Forwarded-For 를 먼저 본다.

    맨 앞 값이 원래 클라이언트다. 프록시를 거칠 때마다 뒤에 붙는다.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def check(scope: str, key: str, limit: int, window_seconds: int):
    """한도를 넘었으면 오류 dict 를, 괜찮으면 None 을 돌려준다.

    Redis 가 없거나 죽으면 통과시킨다. 횟수 제한은 보호 장치이지 정답을
    가르는 것이 아니다. 저장소가 잠깐 흔들렸다고 서비스 전체를 막는 쪽이
    훨씬 나쁘다.
    """
    if not ENABLED or _redis is None:
        return None

    redis_key = f"rl:{scope}:{key}"
    try:
        count = _redis.incr(redis_key)
        if count == 1:
            _redis.expire(redis_key, window_seconds)
        if count <= limit:
            return None
        retry = _redis.ttl(redis_key)
    except Exception:
        return None

    minutes = max(1, (retry if retry and retry > 0 else window_seconds) // 60)
    return {
        "status": 429,
        "message": f"요청이 너무 잦습니다. {minutes}분 뒤에 다시 시도해주세요.",
    }


def limit_ip(request: Request, scope: str, limit: int, window_seconds: int):
    return check(scope, client_ip(request), limit, window_seconds)


def limit_room(room_id: str, scope: str, limit: int, window_seconds: int):
    return check(f"{scope}:room", room_id, limit, window_seconds)


# ── 한도 ────────────────────────────────────────────────────
#
# 서버가 2코어라 4분 곡 분리에 6분 30초가 걸린다. 시간당 아홉 곡이 한계다.
# 그래서 분리 한도는 그 처리량에 맞춰 잡는다. 한 사람이 시간당 다섯 번이면
# 이미 서버의 절반을 쓰는 셈이다.
HOUR = 3600
MINUTE = 60

SEPARATE_PER_IP = (5, HOUR)
SEPARATE_PER_ROOM = (3, HOUR)
UPLOAD_PER_IP = (20, HOUR)
ROOM_CREATE_PER_IP = (10, HOUR)
ROOM_JOIN_PER_IP = (10, MINUTE)
SCORE_PER_IP = (30, HOUR)
