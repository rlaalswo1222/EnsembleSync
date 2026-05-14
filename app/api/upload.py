from fastapi import APIRouter, UploadFile, File, HTTPException
from app.database import get_db, get_redis
import uuid
import json

router = APIRouter()

ALLOWED_EXTENSIONS = {'jpg', 'jpeg', 'png', 'pdf'}

@router.post("/api/score/{room_id}/upload")
async def upload_score(room_id: str, file: UploadFile = File(...)):
    """
    악보 파일 업로드 API
    - 팀 멤버가 악보 사진을 업로드하여 참여자 전원에게 공유
    - UC-03, FR-01
    - 허용 파일: jpg, jpeg, png, pdf
    """
    # 파일 확장자 검증 (score 파일타입 CHECK - S#2 DDL 수정 반영)
    ext = file.filename.split('.')[-1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"지원하지 않는 파일 형식입니다. 허용 형식: {', '.join(ALLOWED_EXTENSIONS)}"
        )

    # 파일 저장 (S3/MinIO URL 생성 - 추후 실제 S3 연동)
    score_id = str(uuid.uuid4())
    file_url = f"https://storage.ensemblesync.com/scores/{room_id}/{score_id}.{ext}"

    return {
        "status": 200,
        "room_id": room_id,
        "score_id": score_id,
        "file_url": file_url,
        "message": "악보가 성공적으로 업로드되었습니다."
    }