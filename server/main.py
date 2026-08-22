from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
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

# 정적 파일 서빙 (업로드된 파일 접근용)
os.makedirs("uploads/scores", exist_ok=True)
os.makedirs("uploads/audio", exist_ok=True)
os.makedirs("uploads/separated", exist_ok=True)
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

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
        "disk_tight": usage["ratio"] >= disk.CLEANUP_HARD_RATIO,
        "accepting_uploads": usage["free_gb"] >= disk.MIN_FREE_UPLOAD_GB,
        "accepting_analysis": usage["free_gb"] >= disk.MIN_FREE_ANALYZE_GB,
    }
