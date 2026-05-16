from fastapi import APIRouter, UploadFile, File, HTTPException
import psycopg2.extras
from database import get_db
import uuid
import shutil
import os

router = APIRouter()

ALLOWED_EXTENSIONS = {'jpg', 'jpeg', 'png', 'pdf'}
UPLOAD_DIR = "uploads/scores"

@router.post("/api/score/{room_id}/upload")
async def upload_score(room_id: str, file: UploadFile = File(...)):
    """
    악보 파일 업로드 API
    - UC-03, FR-01
    - 허용 파일: jpg, jpeg, png, pdf
    """
    conn = None
    try:
        # 1. 파일 확장자 검증
        ext = file.filename.split('.')[-1].lower()
        if ext not in ALLOWED_EXTENSIONS:
            return {
                "status": 400,
                "message": f"지원하지 않는 파일 형식입니다. 허용 형식: {', '.join(ALLOWED_EXTENSIONS)}"
            }

        # 2. room_id 존재 여부 검증
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT id FROM room WHERE id = %s", (room_id,))
        room = cur.fetchone()
        if not room:
            return {"status": 404, "message": "존재하지 않는 방입니다."}

        # 3. 실제 파일 저장
        s