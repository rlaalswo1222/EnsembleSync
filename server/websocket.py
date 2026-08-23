from fastapi import APIRouter, WebSocket, WebSocketDisconnect
import json
import redis
import redis.asyncio as aioredis
import asyncio
import room_auth
from config import REDIS_HOST, REDIS_PORT
from database import get_db

router = APIRouter()

# 방별 참여자 WebSocket { room_id: { user_name: WebSocket } }
_rooms: dict = {}
_redis_tasks: dict = {}  # room_id -> asyncio.Task (Redis pub/sub 리스너)

try:
    _redis = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    _redis.ping()
except Exception:
    _redis = None


async def _redis_listener(room_id: str):
    r = aioredis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
    pubsub = r.pubsub()
    await pubsub.subscribe(f"room_{room_id}")
    try:
        async for message in pubsub.listen():
            if not _rooms.get(room_id):
                break
            if message['type'] == 'message':
                try:
                    data = json.loads(message['data'])
                    await _broadcast(room_id, data)
                except Exception:
                    pass
    except asyncio.CancelledError:
        pass
    finally:
        await pubsub.unsubscribe(f"room_{room_id}")
        await r.aclose()
        _redis_tasks.pop(room_id, None)


def _is_member(room_id: str, token: str | None) -> bool:
    """이 방 사람인지 확인한다.

    WebSocket 은 헤더를 붙일 수 없어서 토큰이 쿼리로 온다.

    여기가 뚫려 있으면 다른 곳을 다 막아도 소용이 없다. 이 연결로 필기가
    실시간으로 흐르고, 분리가 끝나면 파일 주소까지 실려 나간다.
    """
    if not room_auth.ENFORCE:
        return True
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor()
        member = room_auth.member_of(cur, room_id, token)
        cur.close()
        return member is not None
    except Exception:
        # 확인할 수 없으면 막는다. 다른 곳(업로드 등)은 확인 수단이
        # 고장 났을 때 통과시키지만, 여기는 방 안의 모든 것이 흐르는
        # 통로라 반대로 잡는다.
        return False
    finally:
        if conn:
            conn.close()


@router.websocket("/api/ws/room/{room_id}")
async def websocket_endpoint(
    websocket: WebSocket,
    room_id: str,
    user_name: str = "익명",
    room_token: str | None = None,
):
    if not _is_member(room_id, room_token):
        # accept 하기 전에 닫는다. 받아들이고 나서 끊으면 앱은 연결이
        # 됐다가 끊긴 것으로 보고 계속 다시 붙으려 한다.
        await websocket.close(code=4401, reason="not a member")
        return

    await websocket.accept()

    if room_id not in _rooms:
        _rooms[room_id] = {}

    existing_users = list(_rooms[room_id].keys())
    _rooms[room_id][user_name] = websocket

    if room_id not in _redis_tasks:
        _redis_tasks[room_id] = asyncio.create_task(_redis_listener(room_id))

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
            task = _redis_tasks.pop(room_id, None)
            if task:
                task.cancel()
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
