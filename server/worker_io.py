"""일꾼이 서버와 파일을 주고받는 길.

같은 기계에서 도는 일꾼은 서버와 디스크를 함께 쓰므로 아무것도 할 것이
없다. 집 데스크탑처럼 멀리 있는 일꾼만 이 길을 탄다.

    원본  서버에서 내려받는다  (작업 번호만 주고, 경로는 서버가 찾는다)
    결과  tar 로 묶어 올린다   (한 곡에 파일 여덟 개, 300MB 넘음)

Redis 와 데이터베이스는 이 길을 쓰지 않는다. SSH 터널로 서버의
localhost 에 붙으므로 일꾼 코드가 보기에는 그냥 옆에 있는 것과 같다.
그래서 공개된 포트가 하나도 늘지 않는다.
"""
import os
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

# 이 일꾼이 서버 밖에 있는가.
REMOTE = os.getenv("REMOTE_WORKER", "0") == "1"

# 서버 주소. 원격일 때만 쓴다.
SERVER = os.getenv("WORKER_SERVER_URL", "").rstrip("/")

SECRET = os.getenv("WORKER_SECRET", "").strip()

# 내려받을 때 한 번에 읽는 크기.
CHUNK = 1024 * 1024

# 올릴 때 한 번에 소켓에 쓰는 크기.
#
# 실측으로 정했다. 1MB 로 보냈더니 40MB 에 79초(4.2Mbps)가 걸렸는데,
# 같은 기계에서 curl 은 17초(18.9Mbps)에 끝냈다. 4.5배 차이다.
#
# 조각마다 소켓에 쓰고 상대의 응답을 기다리는 왕복이 생기는데, 조각이
# 작을수록 그 왕복이 자주 일어나 회선을 못 채운다. 크게 잡아 밀어붙인다.
UPLOAD_CHUNK = 256 * 1024

# 가끔 끊긴다. 집 인터넷이라 서버끼리 통신할 때보다 흔하다.
RETRIES = 3

# 이번 작업에서 받아온 원본. 끝나면 지워야 한다.
_fetched: list = []


def _headers() -> dict:
    return {"X-Worker-Secret": SECRET}


def _check_config() -> None:
    if not SERVER:
        raise RuntimeError("WORKER_SERVER_URL 이 없습니다.")
    if not SECRET:
        raise RuntimeError("WORKER_SECRET 이 없습니다.")


def fetch_input(job_id: str, file_path: str) -> str:
    """분리할 원본을 가져와 읽을 수 있는 경로를 돌려준다.

    같은 기계면 받은 경로를 그대로 쓴다. 멀리 있으면 내려받는다.
    """
    if not REMOTE:
        return file_path

    _check_config()
    url = f"{SERVER}/api/worker/{job_id}/input"
    suffix = os.path.splitext(file_path)[1] or ".mp3"
    fd, dst = tempfile.mkstemp(suffix=suffix, prefix="bandly_in_")
    os.close(fd)

    last = None
    for attempt in range(RETRIES):
        try:
            req = urllib.request.Request(url, headers=_headers())
            with urllib.request.urlopen(req, timeout=120) as res, \
                    open(dst, "wb") as out:
                while True:
                    chunk = res.read(CHUNK)
                    if not chunk:
                        break
                    out.write(chunk)
            if os.path.getsize(dst) > 0:
                _fetched.append(dst)
                return dst
            last = RuntimeError("빈 파일을 받았습니다.")
        except Exception as e:
            last = e
        # 곧바로 다시 걸지 않는다. 서버가 잠깐 바쁜 것일 수 있다.
        time.sleep(2 * (attempt + 1))

    try:
        os.remove(dst)
    except OSError:
        pass
    raise RuntimeError(f"원본을 내려받지 못했습니다: {last}")


class _Reader:
    """파일을 조금씩 읽어 올리는 객체.

    urllib 에 파일 객체를 그대로 넘기면 통째로 메모리에 올린다. 300MB 를
    한 번에 들고 있을 이유가 없다.
    """

    def __init__(self, path: str):
        self._f = open(path, "rb")
        self.length = os.path.getsize(path)

    def read(self, size: int = -1) -> bytes:
        # urllib 이 넘겨주는 크기를 무시하고 우리가 정한 크기로 읽는다.
        # 기본값을 그대로 두면 한 번에 조금씩만 나가서 회선을 못 채운다.
        return self._f.read(UPLOAD_CHUNK)

    def close(self) -> None:
        self._f.close()


def send_results(job_id: str, output_dir: str) -> None:
    """분리 결과 폴더를 통째로 서버에 올린다.

    같은 기계면 이미 제자리에 있으므로 아무것도 하지 않는다.
    """
    if not REMOTE:
        return

    _check_config()
    url = f"{SERVER}/api/worker/{job_id}/result"

    fd, bundle = tempfile.mkstemp(suffix=".tar", prefix="bandly_out_")
    os.close(fd)
    try:
        # 압축하지 않는다. wav 는 거의 안 줄어드는데 6코어를 몇십 초 더
        # 쓰게 된다. 그 시간이면 그냥 보내는 편이 빠르다.
        with tarfile.open(bundle, "w") as tar:
            for root, _, files in os.walk(output_dir):
                for name in files:
                    full = os.path.join(root, name)
                    rel = os.path.relpath(full, output_dir)
                    tar.add(full, arcname=rel)

        size = os.path.getsize(bundle)
        last = None
        for attempt in range(RETRIES):
            body = _Reader(bundle)
            try:
                req = urllib.request.Request(
                    url,
                    data=body,
                    method="POST",
                    headers={
                        **_headers(),
                        "Content-Type": "application/x-tar",
                        "Content-Length": str(body.length),
                    },
                )
                with urllib.request.urlopen(req, timeout=1800) as res:
                    payload = res.read().decode("utf-8", "replace")
                if '"status": 200' in payload or '"status":200' in payload:
                    print(f"[worker] 결과 {size / 1024 / 1024:.0f}MB 전송 완료")
                    return
                last = RuntimeError(payload[:300])
            except Exception as e:
                last = e
            finally:
                body.close()
            time.sleep(3 * (attempt + 1))

        raise RuntimeError(f"결과를 올리지 못했습니다: {last}")
    finally:
        try:
            os.remove(bundle)
        except OSError:
            pass


def cleanup(output_dir: str) -> None:
    """이 기계에 남은 작업 흔적을 지운다.

    같은 기계에서 도는 일꾼은 아무것도 하지 않는다. 그 파일들이 곧
    서비스가 내보낼 파일이기 때문이다.

    멀리 있는 일꾼에게는 사본일 뿐이다. 서버로 이미 보냈으므로 여기
    남겨둘 이유가 없다. 안 지우면 한 곡마다 300MB 씩 쌓여서 며칠이면
    디스크가 찬다.
    """
    if not REMOTE:
        return

    import shutil

    while _fetched:
        path = _fetched.pop()
        try:
            os.remove(path)
        except OSError:
            pass

    if output_dir and os.path.isdir(output_dir):
        shutil.rmtree(output_dir, ignore_errors=True)


def check_config() -> list:
    """설정이 어긋난 곳을 찾아 목록으로 돌려준다.

    멀리 있는 일꾼은 설정을 손으로 맞춘다. 하나를 빠뜨려도 워커는 멀쩡히
    뜨고 작업도 받는다. 다만 결과가 조용히 못 쓰게 된다.

    실제로 두 개를 빠뜨렸다. PUBLIC_BASE_URL 이 없어 완료 알림에 실린
    주소가 localhost:8000 이 됐고, FILE_SIGNING_SECRET 이 없어 데스크탑이
    자기 열쇠를 새로 만들었다. 서버가 그 서명을 인정하지 않으므로 주소를
    고쳐도 403 이 났을 것이다.

    분리는 성공하고 앱에서만 깨지기 때문에 알아채기까지 오래 걸린다.
    뜰 때 한 번 확인해서 크게 남긴다.
    """
    if not REMOTE:
        return []

    problems = []
    base = os.getenv("PUBLIC_BASE_URL", "")
    if not base or "localhost" in base or "127.0.0.1" in base:
        problems.append(
            "PUBLIC_BASE_URL 이 비었거나 localhost 다. 완료 알림에 실리는 "
            "주소가 앱에서 닿지 않는 곳을 가리키게 된다."
        )
    if not os.getenv("FILE_SIGNING_SECRET", "").strip():
        problems.append(
            "FILE_SIGNING_SECRET 이 없다. 이 기계가 자기 열쇠를 새로 만들어 "
            "서명하므로 서버가 그 주소를 거절한다."
        )
    if not SERVER:
        problems.append("WORKER_SERVER_URL 이 없다. 원본을 받을 곳을 모른다.")
    if not SECRET:
        problems.append("WORKER_SECRET 이 없다. 결과를 올릴 수 없다.")
    return problems
