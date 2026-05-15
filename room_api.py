from fastapi import FastAPI
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware
import random
import string
import psycopg2
import psycopg2.extras

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

def get_db():
    return psycopg2.connect(
        host="localhost",
        database="ensemblesync",
        user="rlaalswo1222",
        password="edu2438!"
    )

def generate_room_code():
    chars = string.ascii_uppercase + string.digits
    return ''.join(random.choice(chars) for _ in range(6))


# ── 방 생성 (/api/room/create) ──────────────────────────────────

class RoomCreateRequest(BaseModel):
    room_name: str
    creator_name: str

@app.post("/api/room/create")
async def create_room(request: RoomCreateRequest):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # Step 1: member 테이블에 방장 추가
        cur.execute(
            "INSERT INTO member (nickname) VALUES (%s) RETURNING id",
            (request.creator_name,)
        )
        member_id = cur.fetchone()['id']

        # Step 2: 중복 없는 room_code 생성
        while True:
            room_code = generate_room_code()
            cur.execute("SELECT 1 FROM room WHERE room_code = %s", (room_code,))
            if not cur.fetchone():
                break

        # Step 3: room 테이블에 방 추가
        cur.execute(
            "INSERT INTO room (room_code, name, created_by) VALUES (%s, %s, %s) RETURNING id",
            (room_code, request.room_name, member_id)
        )
        room_id = cur.fetchone()['id']

        # Step 4: room_participant에 방장(leader)으로 기록
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


# ── 방 입장 (/api/room/join) ────────────────────────────────────

class RoomJoinRequest(BaseModel):
    room_code: str
    user_name: str

@app.post("/api/room/join")
async def join_room(request: RoomJoinRequest):
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # Step 1: room_code로 방 존재 여부 확인
        cur.execute(
            "SELECT id, name, is_active FROM room WHERE room_code = %s",
            (request.room_code,)
        )
        room = cur.fetchone()

        if not room:
            return {"status": 404, "message": "존재하지 않는 방 코드입니다."}

        if not room['is_active']:
            return {"status": 403, "message": "이미 종료된 합주 방입니다."}

        # Step 2: member 테이블에 참여자 추가
        cur.execute(
            "INSERT INTO member (nickname) VALUES (%s) RETURNING id",
            (request.user_name,)
        )
        member_id = cur.fetchone()['id']

        # Step 3: room_participant에 일반 멤버(member)로 기록
        cur.execute(
            "INSERT INTO room_participant (room_id, member_id, role) VALUES (%s, %s, 'member')",
            (room['id'], member_id)
        )

        conn.commit()
        cur.close()
        return {"status": 200, "room_name": room['name'], "message": "입장에 성공했습니다."}

    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방 입장 중 오류가 발생했습니다: {str(e)}"}

    finally:
        if conn:
            conn.close()
