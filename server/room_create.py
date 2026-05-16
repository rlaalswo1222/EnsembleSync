from fastapi import APIRouter
from pydantic import BaseModel
import random
import string
import psycopg2.extras
from database import get_db

router = APIRouter()


class RoomCreateRequest(BaseModel):
    room_name: str
    creator_name: str


def generate_room_code():
    chars = string.ascii_uppercase + string.digits
    return ''.join(random.choice(chars) for _ in range(6))


@router.post("/api/room/create")
async def create_room(request: RoomCreateRequest):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(
            "INSERT INTO member (nickname) VALUES (%s) RETURNING id",
            (request.creator_name,)
        )
        member_id = cur.fetchone()['id']

        while True:
            room_code = generate_room_code()
            cur.execute("SELECT 1 FROM room WHERE room_code = %s", (room_code,))
            if not cur.fetchone():
                break

        cur.execute(
            "INSERT INTO room (room_code, name, created_by) VALUES (%s, %s, %s) RETURNING id",
            (room_code, request.room_name, member_id)
        )
        room_id = cur.fetchone()['id']

        cur.execute(
            "INSERT INTO room_participant (room_id, member_id, role) VALUES (%s, %s, 'leader')",
            (room_id, member_id)
        )

        conn.commit()
        cur.close()
        return {"status": 200, "room_code": room_code, "message": "방이 성공적으로 생성되었습니다."}

    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방 생성 중 오류가 발생했습니다: {str(e)}"}

    finally:
        if conn:
            conn.close()
