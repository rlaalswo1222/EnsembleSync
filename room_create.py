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

# 1. Request 데이터 모델 (API 명세서 유지)
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