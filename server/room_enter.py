from fastapi import APIRouter, Request
from pydantic import BaseModel
import psycopg2
import psycopg2.extras
import ratelimit
import room_auth
from database import get_db

router = APIRouter()


class RoomJoinRequest(BaseModel):
    room_code: str
    user_name: str


@router.post("/api/room/join")
async def join_room(http: Request, request: RoomJoinRequest):
    # 방 코드는 여섯 자리다. 마구 넣어 맞히는 것을 늦춘다.
    limited = ratelimit.limit_ip(
        http, "room_join", *ratelimit.ROOM_JOIN_PER_IP
    )
    if limited:
        return limited

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
        # 이 기기의 열쇠. 방 코드는 여기까지만 쓰이고, 이후 요청은 전부
        # 이 토큰으로 확인한다.
        token = room_auth.issue(cur, room['id'], member_id)

        # 입장은 활동으로 세지 않는다.
        #
        # 세면 정리 예고를 볼 수가 없다. 보려고 들어가는 순간 기한이 다시
        # 30일로 돌아가기 때문이다. 예고를 보고 '보관' 을 누르게 하려면
        # 들여다보는 것과 실제로 쓰는 것을 갈라야 한다.
        #
        # 음원 업로드·분석 요청·악보 업로드만 활동으로 센다.
        conn.commit()
        cur.close()
        return {
            "status": 200,
            "room_name": room['name'],
            "room_id": str(room['id']),
            "room_token": token,
            "message": "입장에 성공했습니다.",
        }

    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방 입장 중 오류가 발생했습니다: {str(e)}"}

    finally:
        if conn:
            conn.close()
