from fastapi import APIRouter, UploadFile, File, HTTPException
from app.database import get_db
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
    # 1. 파일 확장자 검증
    ext = file.filename.split('.')[-1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"지원하지 않는 파일 형식입니다. 허용 형식: {', '.join(ALLOWED_EXTENSIONS)}"
        )

    # 2. room_id 존재 여부 검증
    db = get_db()
    cursor = db.cursor()
    cursor.execute("SELECT id FROM room WHERE id = %s", (room_id,))
    room = cursor.fetchone()
    if not room:
        raise HTTPException(
            status_code=404,
            detail="존재하지 않는 방입니다."
        )

    # 3. 실제 파일 저장
    score_id = str(uuid.uuid4())
    save_dir = f"{UPLOAD_DIR}/{room_id}"
    os.makedirs(save_dir, exist_ok=True)
    file_path = f"{save_dir}/{score_id}.{ext}"

    with open(file_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    # 4. EC2 URL 생성
    file_url = f"http://3.25.160.93:8000/uploads/scores/{room_id}/{score_id}.{ext}"

    # 5. DB에 score 테이블 INSERT
    cursor.execute(
        """
        INSERT INTO score (id, room_id, file_url, file_type, uploaded_at)
        VALUES (%s, %s, %s, %s, now())
        """,
        (score_id, room_id, file_url, ext)
    )
    db.commit()
    cursor.close()
    db.close()

    return {
        "status": 200,
        "room_id": room_id,
        "score_id": score_id,
        "file_url": file_url,
        "message": "악보가 성공적으로 업로드되었습니다."
    }