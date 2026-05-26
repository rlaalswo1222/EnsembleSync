from fastapi import APIRouter, UploadFile, File
import psycopg2.extras
from database import get_db
import uuid
import shutil
import os

router = APIRouter()

ALLOWED_EXTENSIONS = {'mp3', 'wav', 'flac', 'm4a'}
ALLOWED_PURPOSES = {'bpm', 'pitch', 'separation'}
UPLOAD_DIR = "uploads/audio"

@router.post("/api/audio/{room_id}/upload")
async def upload_audio(
    room_id: str,
    purpose: str,
    file: UploadFile = File(...)
):
    """
    음원 파일 업로드 API
    - UC-06, UC-10, UC-12, NR-07
    - 허용 파일: mp3, wav, flac, m4a
    - purpose: bpm / pitch / separation (sync 관련 제거)
    """
    conn = None
    file_path = None
    try:
        # 1. 파일 확장자 검증
        ext = file.filename.split('.')[-1].lower()
        if ext not in ALLOWED_EXTENSIONS:
            return {
                "status": 400,
                "message": f"지원하지 않는 파일 형식입니다. 허용 형식: {', '.join(ALLOWED_EXTENSIONS)}"
            }

        # 2. purpose 검증
        if purpose not in ALLOWED_PURPOSES:
            return {
                "status": 400,
                "message": f"지원하지 않는 purpose입니다. 허용 값: {', '.join(ALLOWED_PURPOSES)}"
            }

        # 3. room_id 존재 여부 검증
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute("SELECT id FROM room WHERE id = %s", (room_id,))
        room = cur.fetchone()
        if not room:
            return {"status": 404, "message": "존재하지 않는 방입니다."}

        # 4. 실제 파일 저장
        audio_id = str(uuid.uuid4())
        save_dir = f"{UPLOAD_DIR}/{room_id}"
        os.makedirs(save_dir, exist_ok=True)
        file_path = f"{save_dir}/{audio_id}.{ext}"

        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)

        # 5. EC2 URL 생성
        file_url = f"http://3.106.49.28:8000/uploads/audio/{room_id}/{audio_id}.{ext}"

        # 6. DB에 audio_file 테이블 INSERT
        cur.execute(
            """
            INSERT INTO audio_file (id, room_id, file_type, file_url, purpose, uploaded_at)
            VALUES (%s, %s, %s, %s, %s, now())
            """,
            (audio_id, room_id, ext, file_url, purpose)
        )
        conn.commit()
        cur.close()

        return {
            "status": 200,
            "room_id": room_id,
            "audio_file_id": audio_id,
            "file_url": file_url,
            "purpose": purpose,
            "message": "음원 파일이 성공적으로 업로드되었습니다."
        }
    except Exception as e:
        if conn:
            conn.rollback()
        # DB 오류 시 서버에서 파일 삭제
        if file_path and os.path.exists(file_path):
            os.remove(file_path)
        return {"status": 500, "message": f"음원 업로드 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()