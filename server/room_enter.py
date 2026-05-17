from fastapi import APIRouter, HTTPException
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
        return {"status": 200, "room_name": room['name'], "message": "입장에 성공했습니다."}

    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"방 입장 중 오류가 발생했습니다: {str(e)}"}

    finally:
        if conn:
            conn.close()


# 방 입장코드 중복 확인 로직 구현
# 1. app = FastAPI() 대신 APIRouter()를 사용
# prefix를 설정해두면 아래 api들의 주소 앞에 자동으로 /api/room이 붙습니다.
router = APIRouter(
    prefix="/api/room",
    tags=["Room"]
)

# Request 데이터 모델
class RoomCodeCheckRequest(BaseModel):
    room_code: str

# 2. @app.post 대신 @router.post를 사용
@router.post("/check-code")
async def check_room_code_duplicate(request: RoomCodeCheckRequest):
    try:
        # ==========================================
        # [DB 조회 로직 시나리오]
        # 실제 DB 연동 시 아래 주석을 풀고 사용하세요.
        # ==========================================
        
        # target_room = db.query(Room).filter(Room.room_code == request.room_code).first()
        
        # 임시 테스트용 조건문 (DB 연동 전)
        # 만약 프론트에서 보낸 코드가 이미 존재하는 코드라면?
        is_duplicate = False # 실제로는 target_room이 존재하는지 여부로 판단
        
        if is_duplicate:
            # 중복(이미 존재하는 방)일 경우 정상적으로 입장 가능함을 알림
            return {
                "status": 200,
                "message": "유효한 방 코드입니다.",
                "is_valid": True
            }
        else:
            # 방이 존재하지 않는 경우 에러(404) 발생
            raise HTTPException(status_code=404, detail="존재하지 않는 방 코드입니다.")

    except HTTPException as he:
        raise he
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"코드 확인 중 서버 오류 발생: {str(e)}")