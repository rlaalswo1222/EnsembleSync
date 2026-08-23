import os.path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

import migrate
import signing
import room_create
import room_enter
import room_status

import disk
import audio_upload
import audio_analysis
import track_download
import score_query
import score_upload
import websocket
import bpm_result
import os

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs("uploads/scores", exist_ok=True)
os.makedirs("uploads/audio", exist_ok=True)
os.makedirs("uploads/separated", exist_ok=True)

UPLOAD_ROOT = os.path.abspath("uploads")


@app.api_route("/uploads/{file_path:path}", methods=["GET", "HEAD"])
async def serve_upload(file_path: str, request: Request):
    """업로드된 파일을 서명이 맞을 때만 내준다.

    전에는 StaticFiles 로 통째로 열어두고 있었다. 주소만 알면 누구나,
    언제까지나 받을 수 있었다는 뜻이다. 이제는 주소에 붙은 유효기간을
    본다. 파일과 DB 는 그대로이므로, 만료된 주소를 쥔 앱은 목록 API 를
    다시 부르면 새 주소를 받는다.

    앱이 그 둘을 구분할 수 있도록 만료는 410, 위조는 403 으로 답한다.
    만료라면 다시 받아서 재시도할 값어치가 있지만 위조는 아니다.
    """
    reason = signing.verify(
        f"/uploads/{file_path}",
        request.query_params.get("exp"),
        request.query_params.get("sig"),
    )
    if reason:
        expired = "유효기간" in reason
        return JSONResponse(
            {"status": 410 if expired else 403, "message": reason},
            status_code=410 if expired else 403,
        )

    # 경로를 실제로 풀어서 uploads 안인지 확인한다. ".." 이 섞인 주소로
    # 서버의 다른 파일을 읽어가는 것을 막는다. 서명이 있어도 확인한다 —
    # 서명을 만드는 쪽이 언젠가 실수할 수 있고, 그때 새는 것이 너무 크다.
    full = os.path.abspath(os.path.join(UPLOAD_ROOT, file_path))
    if not full.startswith(UPLOAD_ROOT + os.sep) or not os.path.isfile(full):
        return JSONResponse(
            {"status": 404, "message": "파일을 찾을 수 없습니다."},
            status_code=404,
        )

    # 주소 자체에 유효기간이 있으므로 그 안에서는 캐시해도 된다. 트랙
    # 하나가 수 MB 라 매번 다시 받게 하면 재생 시작이 눈에 띄게 느려진다.
    return FileResponse(
        full,
        headers={"Cache-Control": f"private, max-age={signing.TTL_SECONDS}"},
    )

# 스키마를 맞춘 뒤에 라우터를 붙인다. DDL 은 DB 를 처음 만들 때만 돌기
# 때문에, 이미 돌고 있는 DB 에 컬럼을 더하려면 여기가 유일한 자리다.
migrate.run()

app.include_router(room_create.router)
app.include_router(room_enter.router)
app.include_router(room_status.router)
app.include_router(audio_upload.router)
app.include_router(audio_analysis.router)
app.include_router(track_download.router)
app.include_router(score_query.router)
app.include_router(score_upload.router)
app.include_router(websocket.router)
app.include_router(bpm_result.router)


@app.get("/api/health")
async def health():
    """서버 상태. 디스크가 얼마나 남았는지 눈으로 확인할 창구다.

    감시 도구를 붙이기 전까지는 이것이 유일하게 들여다보는 방법이다.
    디스크가 차는 것은 서서히 오다가 어느 순간 전부 멈추게 만드는데,
    그 전에 알아차릴 수단이 없으면 손쓸 시간도 없다.
    """
    usage = disk.usage()
    return {
        "status": 200,
        "disk": usage,
        # 서명이 꺼져 있으면 업로드 파일이 그대로 열려 있다는 뜻이다.
        # 조용히 꺼져 있는 것이 제일 나쁘므로 여기서 보이게 한다.
        "file_signing": signing.ENABLED,
        "disk_tight": usage["ratio"] >= disk.CLEANUP_HARD_RATIO,
        "accepting_uploads": usage["free_gb"] >= disk.MIN_FREE_UPLOAD_GB,
        "accepting_analysis": usage["free_gb"] >= disk.MIN_FREE_ANALYZE_GB,
    }
