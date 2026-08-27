"""집 데스크탑이 켜져 있으면 서버 워커를 물러나게 한다.

두 워커가 같은 큐를 보고 있으면 먼저 집는 쪽이 가져간다. 그러면 절반은
느린 쪽으로 간다. 실제로 처음 시험한 작업이 서버로 갔다.

데스크탑이 살아 있는 동안에는 서버 워커가 separation 큐를 듣지 않게 한다.
Celery 의 원격 제어를 쓰므로 컨테이너를 껐다 켤 필요가 없고, 곧바로 먹는다.

데스크탑이 사라지면 다시 듣게 한다. 그래서 데스크탑을 꺼도 서비스가
멈추지 않는다 — 느려질 뿐이다.

취소는 저장되지 않는다. 서버 워커가 다시 뜨면 큐를 다시 듣기 시작한다.
그래서 이 스크립트를 1분마다 돌려 상태를 다시 맞춘다.

    * * * * * cd ~/server && docker compose -f docker-compose.oracle.yml \\
        exec -T api python tools/worker_router.py >> /tmp/router.log 2>&1
"""
import sys

sys.path.insert(0, "/app")

from celery_app import celery_app  # noqa: E402

QUEUE = "separation"

# 집 데스크탑 워커의 이름표. -n desktop@%h 로 띄운다.
REMOTE_PREFIX = "desktop@"

# 서버 안에서 도는 워커의 이름표.
LOCAL_PREFIX = "separation@"

# 데스크탑이 이만큼 연속으로 대답이 없어야 없는 것으로 친다.
#
# 한 번 놓쳤다고 바로 넘기면 안 된다. 코드가 바뀌어 워커를 다시 띄우는
# 20~30초 동안에도 대답이 없는데, 실제로 그 틈에 작업 하나가 느린 쪽으로
# 갔다. 자리를 잠깐 비운 것과 퇴근한 것은 다르다.
#
# 대신 정말 껐을 때 서버가 돌아오는 데 그만큼 늦어진다. 그동안 들어온
# 작업은 큐에서 기다리므로 잃지는 않는다.
MISSES_BEFORE_FALLBACK = 3

# 몇 번 놓쳤는지 기록해 두는 곳. cron 이 매번 새 프로세스로 돌기 때문에
# 파일에 남겨야 이어서 셀 수 있다.
STATE = "/tmp/worker_router.misses"


def _read_misses() -> int:
    try:
        with open(STATE) as f:
            return int(f.read().strip() or 0)
    except Exception:
        return 0


def _write_misses(n: int) -> None:
    try:
        with open(STATE, "w") as f:
            f.write(str(n))
    except Exception:
        pass


def main() -> int:
    control = celery_app.control
    # 짧게 묻는다. 응답이 없는 워커를 오래 기다릴 이유가 없다.
    replies = control.inspect(timeout=3).ping() or {}
    names = list(replies)

    remote = [n for n in names if n.startswith(REMOTE_PREFIX)]
    local = [n for n in names if n.startswith(LOCAL_PREFIX)]

    if not local:
        print("서버 워커가 없다. 할 일 없음.")
        return 0

    if remote:
        _write_misses(0)
        control.cancel_consumer(QUEUE, destination=local)
        print(f"데스크탑({len(remote)}) 있음 → 서버 워커 {local} 물러남")
        return 0

    misses = _read_misses() + 1
    _write_misses(misses)

    if misses < MISSES_BEFORE_FALLBACK:
        print(f"데스크탑 대답 없음 {misses}/{MISSES_BEFORE_FALLBACK} — 기다린다")
        return 0

    control.add_consumer(QUEUE, destination=local)
    print(f"데스크탑 없음({misses}회) → 서버 워커 {local} 복귀")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
