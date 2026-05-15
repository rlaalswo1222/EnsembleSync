from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from app.api import score, upload
import os

app = FastAPI()

# 정적 파일 서빙 (업로드된 악보 파일 접근용)
os.makedirs("uploads/scores", exist_ok=True)
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

# 라우터 등록
app.include_router(score.router)
app.include_router(upload.router)

@app.get("/")
async def root():
    return {"message": "EnsembleSync API 서버 실행 중"}