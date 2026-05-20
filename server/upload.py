from fastapi import APIRouter, UploadFile, File
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
    conn = None
    try:
        ext = file.filename.split('.')[-1].lower()
        if ext not in ALLOWED_EXTENSIONS:
            return {
                "status": 400,
                "message": f"지원하지 않는 파일 형식입니다. 허용 형식: {', '.join(ALLOWED_EXTENSIONS)}"
            }

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT id, created_by FROM room WHERE id = %s", (room_id,))
        room = cur.fetchone()
        if not room:
            return {"status": 404, "message": "존재하지 않는 방입니다."}

        os.makedirs(UPLOAD_DIR, exist_ok=True)
        score_id = str(uuid.uuid4())
        filename = f"{score_id}.{ext}"
        filepath = os.path.join(UPLOAD_DIR, filename)

        with open(filepath, "wb") as f:
            shutil.copyfileobj(file.file, f)

        file_url = f"/uploads/scores/{filename}"

        cur.execute(
            "INSERT INTO score (id, room_id, uploaded_by, file_url, file_type) VALUES (%s, %s, %s, %s, %s)",
            (score_id, room_id, room['created_by'], file_url, ext)
        )
        conn.commit()
        cur.close()

        return {
            "status": 200,
            "room_id": room_id,
            "score_id": score_id,
            "file_url": file_url,
            "message": "악보가 성공적으로 업로드되었습니다."
        }

    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"업로드 중 오류가 발생했습니다: {str(e)}"}

    finally:
        if conn:
            conn.close()
