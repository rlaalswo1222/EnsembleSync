from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import json
import redis

router = APIRouter()

# 방별 참여자 WebSocket { room_id: { user_name: WebSocket } }
_rooms: dict = {}

try:
    _redis = redis.Redis(host='localhost', port=6379, decode_responses=True)
    _redis.ping()
except Exception:
    _redis = None


@router.websocket("/api/ws/room/{room_id}")
async def websocket_endpoint(websocket: WebSocket, room_id: str, user_name: str = "익명"):
    await websocket.accept()

    if room_id not in _rooms:
        _rooms[room_id] = {}

    existing_users = list(_rooms[room_id].keys())
    _rooms[room_id][user_name] = websocket

    # 신규 유저에게 현재 참여자 목록 전송
    if existing_users:
        await websocket.send_text(json.dumps({
            "type": "user_list",
            "users": existing_users
        }))

    # 기존 유저들에게 입장 알림
    await _broadcast(room_id, {"type": "user_joined", "user_name": user_name}, exclude=user_name)

    try:
        while True:
            raw = await websocket.receive_text()
            msg = json.loads(raw)
            msg_type = msg.get("type")

            if msg_type == "draw":
                payload = msg.get("payload", {})
                if _redis:
                    try:
                        _redis.rpush(f"snapshot:{room_id}", json.dumps(payload))
                    except Exception:
                        pass
                await _broadcast(room_id, {"type": "sync_draw", "payload": payload}, exclude=user_name)

            elif msg_type == "erase":
                annotation_id = msg.get("annotation_id")
                if annotation_id and _redis:
                    try:
                        raw_list = _redis.lrange(f"snapshot:{room_id}", 0, -1)
                        _redis.delete(f"snapshot:{room_id}")
                        for raw in raw_list:
                            item = json.loads(raw)
                            if item.get("annotation_id") != annotation_id:
                                _redis.rpush(f"snapshot:{room_id}", raw)
                    except Exception:
                        pass
                await _broadcast(room_id, {"type": "erase", "annotation_id": annotation_id}, exclude=user_name)

            elif msg_type == "clear":
                if _redis:
                    try:
                        _redis.delete(f"snapshot:{room_id}")
                    except Exception:
                        pass
                await _broadcast(room_id, {"type": "clear"}, exclude=user_name)

            elif msg_type == "score_uploaded":
                file_url = msg.get("file_url")
                await _broadcast(room_id, {"type": "score_uploaded", "file_url": file_url}, exclude=user_name)

    except WebSocketDisconnect:
        _rooms[room_id].pop(user_name, None)
        if not _rooms[room_id]:
            del _rooms[room_id]
        await _broadcast(room_id, {"type": "user_left", "user_name": user_name})


async def _broadcast(room_id: str, message: dict, exclude: str = None):
    if room_id not in _rooms:
        return
    disconnected = []
    for name, ws in _rooms[room_id].items():
        if name == exclude:
            continue
        try:
            await ws.send_text(json.dumps(message))
        except Exception:
            disconnected.append(name)
    for name in disconnected:
        _rooms[room_id].pop(name, None)
