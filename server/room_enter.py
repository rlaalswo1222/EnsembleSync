from fastapi import APIRouter
from pydantic import BaseModel
import psycopg2.extras
from database import get_db

router = APIRouter()


class RoomJoinRequest(BaseModel):
    room_code: str
    user_name: str


@router.post("/api/room/join")
async def join_room(request: RoomJoinRequest):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(
            "SELECT id, name, is_active FROM room WHERE room_code = %s",
            (request.room_code,)
        )
        room = cur.fetchone()

        if not room:
            return {"status": 404, "message": "존재하지 않는 방 코드입니다."}

        if not room['is_active']:
            return {"status": 403, "message": "이미 종료된 합주 방입니다."}

        cur.execute(
            "INSERT INTO member (nickname) VALUES (%s) RETURNING id",
            (request.user_name,)
        )
        member_id = cur.fetchone()['id']

        cur.execute(
            "INSERT INTO room_participant (room_id, member_id, role) VALUES (%s, %s, 'member')",
            (room['id'], member_id)
        )

        conn.commit()
        cur.close()
        return {"status": 200, "room_name": room['name'], "room_id": str(room['id']), "message": "입장에 성공했습니다."}

    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방 입장 중 오류가 발생했습니다: {str(e)}"}

    finally:
        if conn:
            conn.close()
