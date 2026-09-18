"""방 참가 자격 확인.

지금까지 방 관련 API 는 room_id 나 job_id 만 알면 전부 열렸다. 방 코드가
한 번 새어 나가면 — 화면 사진 한 장, 대화방 기록 하나 — 그 방의 음원과
분리 트랙은 영영 남의 것이 된다. 회수할 방법도 없었다.

방을 만들거나 들어올 때 토큰을 발급한다. 방 코드는 한 번 쓰는 초대장이
되고, 이후의 열쇠는 이 토큰이다. 기기마다 따로 나가므로 나중에 하나만
끊는 것도 가능하다.

방장 같은 것은 두지 않는다. 합주 연습에 위아래를 만들 이유가 없고,
로그인이 없어서 방장이 앱을 지우면 주인 없는 방이 된다. 들어온 사람은
모두 같은 권한을 가진다.

서명 URL(signing.py)과 층이 다르다. 이쪽은 "누가 주소를 받을 자격이
있나", 저쪽은 "그 주소가 언제까지 유효한가" 를 맡는다.
"""
import os
import secrets

from fastapi import Request

from config import ROOM_INACTIVE_DAYS

HEADER = "x-room-token"

# 헤더를 못 붙이는 자리(WebSocket)를 위한 쿼리 이름.
QUERY = "room_token"

# 끄는 스위치.
#
# 토큰을 요구하기 시작하면 예전 앱은 전부 막힌다. 배포 직후에 무언가
# 어긋났을 때 서버에 붙어 이것만 0 으로 두면 되돌릴 수 있다. 되돌릴
# 방법이 재배포뿐이면 그 몇 분 동안 아무도 앱을 못 쓴다.
ENFORCE = os.getenv("ROOM_AUTH_ENFORCE", "1") == "1"

DENIED = {
    "status": 401,
    "message": "이 방에 접근할 권한이 없습니다. 방 코드로 다시 입장해주세요.",
}

# 방이 정리되어 사라진 경우.
#
# 권한 없음과 갈라서 답한다. 예전에는 둘을 같은 응답으로 묶었는데, 그
# 바람에 이미 지워진 방을 열면 "방 코드로 다시 입장해주세요" 라는 말이
# 나왔다. 코드를 넣어도 없는 방이라 또 실패한다. 앱이 고장 난 것처럼
# 보인다.
#
# 방 코드로 들어오는 자리(room_enter)는 지금처럼 묶어 둔다. 여섯 자리
# 코드는 하나씩 넣어보며 실재하는 방을 골라낼 수 있기 때문이다. 이쪽은
# UUID 를 받는 자리라 찍어서 맞힐 수가 없어 갈라도 안전하다.
GONE = {
    "status": 410,
    "message": (
        f"이 방은 {ROOM_INACTIVE_DAYS}일 넘게 쓰지 않아 정리되었습니다."
    ),
}


def new_token() -> str:
    return secrets.token_urlsafe(32)


def token_from(request: Request) -> str | None:
    return request.headers.get(HEADER) or request.query_params.get(QUERY)


def issue(cur, room_id: str, member_id: str) -> str:
    """이 참가자의 토큰을 만들어 넣고 돌려준다."""
    token = new_token()
    cur.execute(
        "UPDATE room_participant SET token = %s "
        "WHERE room_id = %s AND member_id = %s",
        (token, room_id, member_id),
    )
    return token


def member_of(cur, room_id: str, token: str | None) -> str | None:
    """토큰이 이 방의 것이면 member_id 를, 아니면 None 을 돌려준다."""
    if not token:
        return None
    cur.execute(
        "SELECT member_id::text FROM room_participant "
        "WHERE token = %s AND room_id = %s",
        (token, room_id),
    )
    row = cur.fetchone()
    if not row:
        return None
    # RealDictCursor 와 기본 커서를 둘 다 쓰는 곳에서 불린다.
    return row["member_id"] if isinstance(row, dict) else row[0]


def room_of_job(cur, job_id: str) -> str | None:
    """job_id 로 들어오는 API 를 위해 그 작업이 속한 방을 찾는다."""
    try:
        cur.execute(
            "SELECT room_id::text FROM analysis_job WHERE id = %s", (job_id,)
        )
    except Exception:
        # job_id 가 UUID 형식이 아니면 여기서 터진다. 없는 것과 같다.
        return None
    row = cur.fetchone()
    if not row:
        return None
    return row["room_id"] if isinstance(row, dict) else row[0]


def room_exists(cur, room_id: str) -> bool:
    try:
        cur.execute("SELECT 1 FROM room WHERE id = %s", (room_id,))
    except Exception:
        # UUID 형식이 아니면 여기서 터진다. 없는 것과 같다.
        return False
    return cur.fetchone() is not None


def require(cur, request: Request, room_id: str | None):
    """자격이 없으면 오류 dict 를, 있으면 None 을 돌려준다.

    막을 때 두 가지로 갈라 답한다. 방이 사라진 것과 열쇠가 안 맞는 것은
    사용자가 할 일이 다르다 — 앞의 경우는 새 방을 만들어야 하고, 뒤의
    경우는 방 코드로 다시 들어오면 된다.

    room_id 가 None 이면 대상 자체를 못 찾은 것이라 갈라줄 수가 없다.
    """
    if not ENFORCE:
        return None
    if not room_id:
        return DENIED
    try:
        if member_of(cur, room_id, token_from(request)):
            return None
    except Exception:
        # 질의가 실패했다. 막는 쪽으로 답한다.
        return DENIED
    return DENIED if room_exists(cur, room_id) else GONE
