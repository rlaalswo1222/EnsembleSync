import os
from urllib.parse import urlparse

from dotenv import load_dotenv

load_dotenv()

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "http://localhost:8000").rstrip("/")

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))


def public_url(path: str) -> str:
    return f"{PUBLIC_BASE_URL}/{path.lstrip('/')}"


def normalize_public_url(url: str) -> str:
    path = urlparse(url).path
    return public_url(path) if path else url


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
