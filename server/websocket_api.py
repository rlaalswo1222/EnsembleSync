from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from typing import Dict, List
import json

# 1. 모듈화 라우터 설정 (엔드포인트) : 기본 주소 설정
router = APIRouter(
    prefix="/api/ws",
    tags=["WebSocket"]
)

# 2. 방별 참여자 연결 관리 (Connection Manager)
class ConnectionManager:
    def __init__(self):
        # 방 번호를 Key로, 접속한 사람들의 WebSocket 목록을 Value로 저장
        # 예: {"a1b2c3": [websocket1, websocket2]}
        self.active_connections: Dict[str, List[WebSocket]] = {}

    async def connect(self, websocket: WebSocket, room_id: str):
        await websocket.accept()
        if room_id not in self.active_connections:
            self.active_connections[room_id] = []
        self.active_connections[room_id].append(websocket)

    def disconnect(self, websocket: WebSocket, room_id: str):
        if room_id in self.active_connections:
            self.active_connections[room_id].remove(websocket)
            # 방에 아무도 없으면 방 목록에서 삭제
            if not self.active_connections[room_id]:
                del self.active_connections[room_id]

    # 3. 필기 데이터 브로드캐스트 (나를 제외한 같은 방 사람들에게 전송)
    async def broadcast(self, message: str, room_id: str, sender: WebSocket):
        if room_id in self.active_connections:
            for connection in self.active_connections[room_id]:
                if connection != sender:
                    await connection.send_text(message)

manager = ConnectionManager()


# 4. 비정상 좌표 유효성 검증 함수
def is_valid_coordinates(stroke_data: List[dict]) -> bool:
    for point in stroke_data:
        x, y = point.get("x"), point.get("y")
        # x, y가 없거나 0.0 ~ 1.0 범위를 벗어나면 비정상
        if x is None or y is None or not (0.0 <= x <= 1.0) or not (0.0 <= y <= 1.0):
            return False
    return True


# 실제 웹소켓 엔드포인트 : 창구 주소 설정
@router.websocket("/room/{room_id}")
async def websocket_endpoint(websocket: WebSocket, room_id: str):
    # 유저가 방에 입장하면 매니저에 등록
    await manager.connect(websocket, room_id)
    
    try:
        while True:
            # 프론트에서 보낸 데이터 수신
            data = await websocket.receive_text()
            message = json.loads(data)

            # 명세서에 정의한 "draw" 타입인지 확인
            if message.get("type") == "draw":
                payload = message.get("payload", {})
                stroke_data = payload.get("stroke_data", [])

                # 유효성 검증 실행
                if not is_valid_coordinates(stroke_data):
                    # 비정상 좌표면 그린 사람에게만 에러 전송
                    await websocket.send_json({"type": "error", "message": "비정상적인 좌표입니다."})
                    continue

                # ==========================================
                # [Redis 연동 파트] 
                # 준호 님이 Redis 세팅을 끝내면 여기에 RPUSH 로직 추가!
                # ==========================================

                # 유효한 좌표라면 브로드캐스트 데이터 조립
                broadcast_msg = {
                    "type": "sync_draw",
                    "payload": payload
                }
                # 같은 방 사람들에게 전송
                await manager.broadcast(json.dumps(broadcast_msg), room_id, sender=websocket)

    except WebSocketDisconnect:
        # 유저가 연결을 끊고 나가면 매니저에서 삭제
        manager.disconnect(websocket, room_id)