"""멀리 있는 분석 일꾼이 결과를 되돌려 보내는 창구.

지금까지 API 와 워커는 같은 기계에서 같은 디스크를 봤다. 워커가 파일을
쓰면 API 가 그 자리에서 읽어 내보내면 됐다.

집 데스크탑을 일꾼으로 붙이면 그게 안 된다. 그 기계는 서버의 디스크를 볼
수 없다. 그래서 원본은 서명된 주소로 내려받고, 결과는 여기로 올린다.

한 곡의 결과가 300MB를 넘는다(무손실 wav 4개 + 재생용 mp3 4개). 파일을
하나씩 올리면 왕복이 여덟 번이라, tar 로 묶어 한 번에 흘려보낸다.

들어오는 것을 그대로 믿지 않는다. tar 안의 경로가 상위로 빠져나가면
서버의 아무 파일이나 덮어쓸 수 있다. 한 항목씩 풀면서 확인한다.
"""
import hmac
import os
import tarfile

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse

from config import SEPARATED_DIR, WORKER_SECRET, local_upload_path
from database import get_db

router = APIRouter()

# 한 작업이 올릴 수 있는 최대 크기.
#
# 4분 곡이 337MB 였다. 10분짜리를 올리는 사람이 있어도 견디도록 잡되,
# 무한정 받지는 않는다.
MAX_RESULT_MB = int(os.getenv("MAX_RESULT_MB", "1200"))

# tar 안에서 허용하는 확장자. 분리 결과는 이게 전부다.
ALLOWED_SUFFIXES = {".wav", ".mp3", ".json"}


def _authorized(request: Request) -> bool:
    """워커가 맞는지 확인한다.

    compare_digest 를 쓴다. 문자열을 == 로 견주면 앞에서 몇 글자가 맞는지에
    따라 걸리는 시간이 달라져서, 그 차이로 열쇠를 한 글자씩 알아낼 수 있다.
    """
    if not WORKER_SECRET:
        return False
    got = request.headers.get("x-worker-secret", "")
    return hmac.compare_digest(got, WORKER_SECRET)


def _safe_members(tar: tarfile.TarFile, root: str):
    """tar 항목 중 안전한 것만 걸러 내놓는다.

    막는 것:
      · 상위로 빠져나가는 경로 (../../etc/passwd)
      · 절대 경로
      · 심볼릭 링크·하드 링크 (링크를 따라가면 바깥을 건드릴 수 있다)
      · 분리 결과가 아닌 확장자
    """
    for member in tar:
        if member.islnk() or member.issym():
            continue
        if not member.isfile():
            continue
        if os.path.splitext(member.name)[1].lower() not in ALLOWED_SUFFIXES:
            continue

        target = os.path.realpath(os.path.join(root, member.name))
        if not target.startswith(os.path.realpath(root) + os.sep):
            continue
        yield member


@router.get("/api/worker/{job_id}/input")
async def send_input(job_id: str, request: Request):
    """분리할 원본 음원을 워커에게 내준다.

    워커가 경로를 들고 오게 하지 않는다. 작업 번호만 받고 서버가 DB 에서
    찾는다. 경로를 받으면 그것을 검사하는 짐이 생기고, 한 번 실수하면
    서버의 아무 파일이나 빼갈 수 있다.
    """
    if not _authorized(request):
        return {"status": 403, "message": "워커 인증에 실패했습니다."}

    conn = None
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT af.file_url
            FROM analysis_job aj
            JOIN audio_file af ON af.id = aj.audio_file_id
            WHERE aj.id = %s
            """,
            (job_id,),
        )
        row = cur.fetchone()
        cur.close()
        if not row:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}

        path = local_upload_path(row[0])
        if not os.path.isfile(path):
            return {"status": 404, "message": "원본 파일이 없습니다."}
        return FileResponse(path, filename=os.path.basename(path))
    except Exception as e:
        return {"status": 500, "message": f"원본을 내주지 못했습니다: {e}"}
    finally:
        if conn:
            conn.close()


@router.post("/api/worker/{job_id}/result")
async def receive_result(job_id: str, request: Request):
    """분리 결과 묶음을 받아 푼다."""
    if not _authorized(request):
        return {"status": 403, "message": "워커 인증에 실패했습니다."}

    # job_id 는 경로가 되므로 형태를 확인한다. UUID 가 아니면 받지 않는다.
    if not job_id.replace("-", "").isalnum() or len(job_id) > 64:
        return {"status": 400, "message": "작업 번호가 올바르지 않습니다."}

    root = os.path.join(SEPARATED_DIR, job_id)
    os.makedirs(root, exist_ok=True)
    bundle = os.path.join(root, ".incoming.tar")

    limit = MAX_RESULT_MB * 1024 * 1024
    written = 0
    try:
        with open(bundle, "wb") as out:
            async for chunk in request.stream():
                written += len(chunk)
                if written > limit:
                    raise ValueError("too large")
                out.write(chunk)

        with tarfile.open(bundle, "r:*") as tar:
            names = []
            for member in _safe_members(tar, root):
                tar.extract(member, root, filter="data")
                names.append(member.name)

        if not names:
            return {"status": 400, "message": "쓸 수 있는 파일이 없습니다."}

        return {
            "status": 200,
            "job_id": job_id,
            "files": len(names),
            "bytes": written,
        }
    except ValueError:
        return {
            "status": 413,
            "message": f"결과가 너무 큽니다. {MAX_RESULT_MB}MB 이하만 받습니다.",
        }
    except Exception as e:
        return {"status": 500, "message": f"결과를 받지 못했습니다: {e}"}
    finally:
        try:
            os.remove(bundle)
        except OSError:
            pass
