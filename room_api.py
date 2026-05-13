from fastapi import FastAPI
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware  # CORS 도구
import random
import string
import uuid

app = FastAPI()

# 브라우저에게 CORS 알려주기
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 일단 개발 중에는 모든 곳(*)에서 오는 요청 허락
    allow_credentials=True,
    allow_methods=["*"],  # GET, POST 등 모든 방식 허락
    allow_headers=["*"],  # 모든 데이터 형식 허락
)

# 1. 방 생성 로직 (/api/room/create)
class RoomCreateRequest(BaseModel):
    room_name: str
    creator_name: str

# 6자리 랜덤 방 코드를 생성하는 함수
def generate_room_code():
    letters_and_digits = string.ascii_uppercase + string.digits
    return ''.join(random.choice(letters_and_digits) for i in range(6))

# 2. 방 생성 API 엔드포인트
@app.post("/api/room/create")
async def create_room(request: RoomCreateRequest):
    try:
        new_room_code = generate_room_code()
        
        # ==========================================
        # 🚨 [DB 처리 로직 시나리오 (ERD 기반)]
        # 실제 PostgreSQL 연결 코드는 생략하고 흐름(SQL)만 주석으로 작성했습니다.
        # ==========================================
        
        # Step 1: member 테이블에 사용자(작성자) 추가
        # INSERT INTO member (nickname) VALUES (request.creator_name) RETURNING id;
        # (가정) DB에서 방금 생성된 member의 UUID를 가져옵니다.
        # new_member_id = 발급된 UUID
        
        # Step 2: room 테이블에 방 정보 추가
        # ERD 변수 매칭: name = request.room_name, room_code = new_room_code, created_by = new_member_id
        # INSERT INTO room (room_code, name, created_by) 
        # VALUES (new_room_code, request.room_name, new_member_id) RETURNING id;
        # (가정) DB에서 방금 생성된 room의 UUID를 가져옵니다.
        # new_room_id = 발급된 UUID
        
        # Step 3: room_participant 테이블에 방장 권한으로 참여 기록 추가
        # INSERT INTO room_participant (room_id, member_id, role) 
        # VALUES (new_room_id, new_member_id, 'leader');
        
        # ==========================================
        
        # Step 4: API 명세서 약속대로 응답 반환
        return {
            "status": 200,
            "room_code": new_room_code,
            "message": "방이 성공적으로 생성되었습니다."
        }
        
    except Exception as e:
        return {
            "status": 500,
            "message": f"방 생성 중 오류가 발생했습니다: {str(e)}"
        }
        
        
# 2. 방 입장 로직 (/api/room/join)
# ==========================================
# 프론트엔드가 보낼 방 입장 데이터 양식 (API 명세서 기준)
class RoomJoinRequest(BaseModel):
    room_code: str
    user_name: str

@app.post("/api/room/join")
async def join_room(request: RoomJoinRequest):
    try:
        # ==========================================
        # 🚨 [DB 처리 로직 시나리오 (ERD 기반)]
        # DB 연결 코드가 세팅되면 주석을 해제하고 변수 맞추기
        # ==========================================

        # Step 1: room 테이블에서 room_code로 방 존재 여부 조회
        # target_room = db.query(Room).filter(Room.room_code == request.room_code).first()
        # if not target_room:
        #     return {"status": 404, "message": "존재하지 않는 방 코드입니다."}

        # Step 2: 🛡️ 방이 비활성화(is_active=False) 상태인지 확인
        # if not target_room.is_active:
        #     return {"status": 403, "message": "이미 종료된 합주 방입니다."}

        # Step 3: 🛡️ 중복 참여 확인 (동일한 닉네임이 해당 방에 있는지)
        # existing_participant = db.query(Participant).join(Member).filter(
        #     Participant.room_id == target_room.id,
        #     Member.nickname == request.user_name
        # ).first()
        # if existing_participant:
        #     return {"status": 200, "message": "이미 참여 중인 방입니다.", "room_name": target_room.name}

        # Step 4: member 테이블에 사용자(참여자) 정보 추가 및 ID 발급
        # new_member = Member(nickname=request.user_name)
        # db.add(new_member)
        # db.flush()

        # Step 5: room_participant 테이블에 일반 멤버(role='member')로 기록 추가
        # new_participant = Participant(room_id=target_room.id, member_id=new_member.id, role='member')
        # db.add(new_participant)
        # db.commit()

        # ==========================================

        # Step 6: API 명세서 약속대로 응답 반환 (DB 연동 전 테스트용 응답)
        return {
            "status": 200,
            "room_name": "4EVER 합주방 (테스트)", # 실제로는 target_room.name 반환
            "message": "입장에 성공했습니다."
        }

    except Exception as e:
        return {
            "status": 500,
            "message": f"방 입장 중 오류가 발생했습니다: {str(e)}"
        }