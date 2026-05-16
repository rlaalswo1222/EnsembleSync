from fastapi import APIRouter
import psycopg2.extras
from database import get_db
import json
import redis

router = APIRouter()

redis_client = redis.Redis(host='localhost', port=6379, decode_responses=True)

@router.get("/api/score/{room_id}/snapshot")
async def get_score_snapshot(room_id: str):
    """
    악보 스냅샷 반환 API
    - 새 참여자가 방 입장 시 기존 필기 목록 전체를 반환
    - UC-04 기본흐름 3a: WebSocket 재연결 후 스냅샷 수신으로 복원
    """
    try:
        key = f"snapshot:{room_id}"
        strokes = redis_client.lrange(key, 0, -1)

        if not strokes:
            return {
                "status": 200,
                "room_id": room_id,
                "strokes": [],
                "message": "필기 데이터가 없습니다."
            }

        parsed_strokes = [json.loads(s) for s in strokes]

        return {
            "status": 200,
            "room_id": room_id,
            "strokes": parsed_strokes,
            "message": f"총 {len(parsed_strokes)}개의 필기 데이터를 반환합니다."
        }
    except Exception as e:
        return {"status": 500, "message": f"스냅샷 조회 중 오류가 발생했습니다: {str(e)}"}