import os
from urllib.parse import urlparse

from dotenv import load_dotenv

import signing

load_dotenv()

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))


def signed_path(path: str) -> str:
    """`/uploads/...` 상대 경로에 유효기간 서명을 붙인다.

    앱이 절대 주소 대신 상대 경로를 받아 쓰는 자리(악보)가 있어서 따로
    둔다. 서명은 경로에 대해 걸리므로 여기서 붙이나 public_url 에서
    붙이나 같은 값이 나온다.
    """
    return signing.sign_path(path)


def public_url(path: str) -> str:
    return f"{PUBLIC_BASE_URL}/{signing.sign_path(path).lstrip('/')}"


def normalize_public_url(url: str) -> str:
    """DB 에 담긴 경로나 예전 절대 주소를 지금 서버의 서명된 주소로 바꾼다.

    쿼리는 버리고 경로만 남긴다. 이미 서명이 붙어 있던 주소를 다시 넣어도
    서명이 겹치지 않게 하려는 것이다.
    """
    path = urlparse(url).path
    return public_url(path) if path else url


def touch_room(cur, room_id: str) -> None:
    """방에서 무언가 일어났다고 표시한다.

    음원 업로드 · 분석 요청 · 악보 업로드에서만 부른다. 입장은 부르지
    않는다. 들여다보는 것까지 활동으로 세면 정리 예고를 볼 수가 없다.
    보려고 들어가는 순간 기한이 다시 늘어나기 때문이다.

    정리 정책이 이 값을 본다. 실패해도 본 작업을 막지 않는다 — 활동 표시가
    한 번 빠지는 것보다 업로드나 분석이 실패하는 쪽이 훨씬 나쁘다.
    """
    try:
        cur.execute(
            "UPDATE room SET last_active_at = now() WHERE id = %s", (room_id,)
        )
    except Exception:
        pass


def local_upload_path(url: str) -> str:
    path = urlparse(url).path.lstrip("/")
    if not path.startswith("uploads/"):
        raise ValueError("Invalid upload URL")
    return path


# 업로드 한 건의 최대 크기.
#
# 지금까지 크기 검사가 없었다. 확장자만 봤기 때문에 누가 2GB 파일을 올리면
# 그대로 받아 디스크를 채우고, demucs 가 몇 시간을 물고 늘어지는 동안 다른
# 모든 사용자가 멈춘다. 악의가 없어도 실수 한 번으로 서비스가 죽는다.
MAX_AUDIO_MB = int(os.getenv("MAX_AUDIO_MB", "100"))


def save_upload_limited(src, dst_path: str, max_bytes: int) -> bool:
    """업로드를 파일로 옮기되 한도를 넘으면 중간에 그만둔다.

    다 받은 뒤에 크기를 재면 이미 디스크를 쓴 뒤라 늦다. 받으면서 세다가
    넘으면 쓰던 파일을 지우고 False 를 돌려준다.
    """
    written = 0
    with open(dst_path, "wb") as out:
        while True:
            chunk = src.read(1024 * 1024)
            if not chunk:
                return True
            written += len(chunk)
            if written > max_bytes:
                break
            out.write(chunk)

    try:
        os.remove(dst_path)
    except OSError:
        pass
    return False


# ── 보관 정책 ────────────────────────────────────────────────
# 정리 작업(cleanup)과 조회 API(room_status)가 같은 값을 봐야 하므로
# 여기 둔다. 어느 한쪽에 두면 나머지가 그 모듈을 통째로 끌어오게 된다.

# 활성 방 안에서 오래된 분리 결과를 지우는 기준.
SEPARATED_RETENTION_DAYS = int(os.getenv("SEPARATED_RETENTION_DAYS", "14"))

# 이만큼 아무 일도 없으면 그 방을 통째로 지운다.
#
# 분리 결과만 지우고 방을 남기는 방법도 있었지만, 그러면 한 번 쓴 방이
# 영원히 쌓인다. 방 코드는 여섯 자리뿐이라 언젠가 마른다.
ROOM_INACTIVE_DAYS = int(os.getenv("ROOM_INACTIVE_DAYS", "20"))

# 정리까지 이만큼 남았을 때부터 앱에 알린다.
ROOM_WARN_WITHIN_DAYS = int(os.getenv("ROOM_WARN_WITHIN_DAYS", "7"))

SEPARATED_DIR = "uploads/separated"
