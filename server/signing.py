"""파일 주소에 유효기간을 붙인다.

지금까지 uploads 아래는 전부 그냥 열려 있었다. 주소를 한 번 얻은 사람은
영원히 받을 수 있었다. 방에서 나가도, 링크를 남에게 넘겨도 막을 방법이
없었다. 올라오는 음원이 대개 남의 저작물이라 그대로 둘 상태가 아니었다.

서명을 헤더가 아니라 주소 안에 넣는다. 앱이 트랙을 SoLoud 의 loadUrl 로
재생하는데 거기엔 헤더를 붙일 자리가 없기 때문이다.

    /uploads/separated/<job>/vocals.mp3?exp=1755950400&sig=a3f9...

exp 가 지나면 서버가 거절한다. 파일도 DB 도 그대로다. 만료되는 것은
주소뿐이라, 방에 다시 들어오면 그 자리에서 새로 서명해서 내려준다.
"""
import hashlib
import hmac
import logging
import os
import time

from dotenv import load_dotenv

# config 가 이 모듈을 먼저 불러오므로 여기서도 .env 를 읽어야 한다.
# 두 번 불러도 무해하다.
load_dotenv()

log = logging.getLogger(__name__)

# 주소가 살아 있는 시간.
#
# 짧을수록 유출된 링크가 빨리 죽지만, 앱을 켜둔 채 오래 있다가 재생을
# 누르는 경우 만료된 주소를 쥐고 있게 된다. 앱이 403 을 받으면 목록을
# 다시 받아오므로 사용자는 못 느끼지만, 굳이 자주 겪게 할 이유는 없다.
TTL_SECONDS = int(os.getenv("FILE_URL_TTL_HOURS", "24")) * 3600

# 시계 오차 여유. 컨테이너들이 같은 호스트를 쓰므로 크게 잡을 필요는 없다.
CLOCK_SKEW = 60

# 서명 길이. hex 32자 = 128비트. 위조를 막기에 충분하고 주소가 덜 길어진다.
SIG_LENGTH = 32

_KEY_FILE = "uploads/.signing_key"


def _load_key() -> bytes:
    """서명 열쇠를 얻는다.

    환경변수가 있으면 그것을 쓴다. 없으면 uploads 아래에 만들어 둔다.
    api 와 워커가 uploads 볼륨을 함께 마운트하므로, 파일에 두면 양쪽이
    설정 없이도 같은 열쇠를 보게 된다. 배포할 때 환경변수를 빠뜨려서
    서명이 조용히 꺼져 있는 상황을 피하려는 것이다.
    """
    env = os.getenv("FILE_SIGNING_SECRET", "").strip()
    if env:
        return env.encode()

    try:
        if os.path.exists(_KEY_FILE):
            with open(_KEY_FILE, "rb") as f:
                key = f.read().strip()
            if key:
                return key

        os.makedirs(os.path.dirname(_KEY_FILE), exist_ok=True)
        key = os.urandom(32).hex().encode()
        # O_EXCL 로 만든다. api 와 워커가 동시에 뜨면 둘 다 여기 오는데,
        # 나중 것이 덮어쓰면 앞서 서명한 주소가 전부 죽는다.
        try:
            fd = os.open(_KEY_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            with open(_KEY_FILE, "rb") as f:
                return f.read().strip()
        with os.fdopen(fd, "wb") as f:
            f.write(key)
        return key
    except OSError as e:
        # 열쇠를 못 만들면 서명 없이 돈다. 파일 접근이 막히는 것보다는
        # 낫지만 보호가 없는 상태이므로 크게 남긴다.
        log.error("서명 열쇠를 만들지 못했습니다. 파일 주소가 보호되지 "
                  "않습니다: %s", e)
        return b""


_KEY = _load_key()

ENABLED = bool(_KEY)


def _signature(path: str, exp: int) -> str:
    return hmac.new(
        _KEY, f"{path}:{exp}".encode(), hashlib.sha256
    ).hexdigest()[:SIG_LENGTH]


def sign_path(path: str, ttl: int = TTL_SECONDS) -> str:
    """`/uploads/...` 경로에 exp 와 sig 를 붙여 돌려준다.

    이미 서명이 붙어 있거나 uploads 밖이면 그대로 둔다. 두 번 서명하면
    앞의 것이 뒤에 가려 검증이 어긋난다.
    """
    if not _KEY or not path.startswith("/uploads/") or "sig=" in path:
        return path
    exp = int(time.time()) + ttl
    return f"{path}?exp={exp}&sig={_signature(path, exp)}"


def verify(path: str, exp, sig) -> str | None:
    """맞으면 None, 아니면 거절 사유를 돌려준다."""
    if not _KEY:
        return None
    if not sig or exp is None:
        return "서명이 없는 주소입니다."
    try:
        exp = int(exp)
    except (TypeError, ValueError):
        return "주소 형식이 올바르지 않습니다."

    # 유효기간을 먼저 본다. 만료와 위조는 앱이 다르게 다뤄야 한다 —
    # 만료면 목록을 다시 받아 재시도할 값어치가 있지만 위조는 아니다.
    if exp + CLOCK_SKEW < int(time.time()):
        return "주소의 유효기간이 지났습니다."
    if not hmac.compare_digest(_signature(path, exp), sig):
        return "주소가 올바르지 않습니다."
    return None
