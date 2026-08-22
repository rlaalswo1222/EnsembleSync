"""디스크 여유 확인.

디스크가 차면 조용히 죽는다. demucs 가 파일을 쓰다 실패하고, 이어서 DB
쓰기까지 막혀서 앱 전체가 멈춘다. 그것도 분리를 몇 분 돌린 뒤에 그렇게
된다.

터진 뒤에 알려주는 것보다 미리 거절하는 편이 낫다. "지금은 공간이 없다"
는 응답은 사용자가 이해할 수 있지만, 6분을 기다린 끝의 정체불명 실패는
그렇지 않다.

uploads 는 호스트 디스크를 그대로 마운트한 것이라 컨테이너에서 재도 호스트
값이 나온다.
"""
import os
import shutil

UPLOAD_ROOT = "uploads"

# 업로드를 받지 않기 시작하는 여유 공간.
#
# 6트랙 분리 하나가 결과 300MB 에 작업용 임시 WAV 까지 1GB 가까이 쓴다.
# 몇 건이 동시에 몰려도 버티도록 잡는다.
MIN_FREE_UPLOAD_GB = float(os.getenv("MIN_FREE_UPLOAD_GB", "5"))

# 분리를 시작하지 않는 여유 공간. 업로드보다 낮게 둔다.
#
# 이미 올라온 음원을 분석하는 것은 마지막까지 기회를 준다. 여기서 막히면
# 사용자는 파일을 올려놓고 아무것도 못 하는 상태가 된다.
MIN_FREE_ANALYZE_GB = float(os.getenv("MIN_FREE_ANALYZE_GB", "3"))

# 이 비율을 넘으면 정리를 평소보다 세게 돌린다.
CLEANUP_HARD_RATIO = float(os.getenv("CLEANUP_HARD_RATIO", "0.8"))

GB = 1024 ** 3


def usage() -> dict:
    total, used, free = shutil.disk_usage(UPLOAD_ROOT)
    return {
        "total_gb": round(total / GB, 1),
        "used_gb": round(used / GB, 1),
        "free_gb": round(free / GB, 1),
        "ratio": round(used / total, 3) if total else 0.0,
    }


def free_gb() -> float:
    try:
        return shutil.disk_usage(UPLOAD_ROOT).free / GB
    except OSError:
        # 디스크를 못 읽는 상황이라면 막기보다 통과시킨다. 확인 수단이
        # 고장 났다고 서비스를 세울 이유는 없다.
        return float("inf")


def is_tight() -> bool:
    """정리를 세게 돌려야 할 만큼 찼는가."""
    try:
        return usage()["ratio"] >= CLEANUP_HARD_RATIO
    except OSError:
        return False


def guard_upload():
    """업로드를 받을 수 있는지. 안 되면 오류 dict 를 돌려준다."""
    free = free_gb()
    if free >= MIN_FREE_UPLOAD_GB:
        return None
    return {
        "status": 507,
        "message": "서버 저장 공간이 부족합니다. 잠시 후 다시 시도해주세요.",
    }


def guard_analyze():
    free = free_gb()
    if free >= MIN_FREE_ANALYZE_GB:
        return None
    return {
        "status": 507,
        "message": "서버 저장 공간이 부족해 분석을 시작할 수 없습니다.",
    }
