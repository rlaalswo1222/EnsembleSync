from fastapi import APIRouter, HTTPException
from app.database import get_redis

router = APIRouter()

@router.get("/api/score/{room_id}/snapshot")
async def get_score_snapshot(room_id: str):
    """
    악보 스냅샷 반환 API
    - 새 참여자가 방 입장 시 기존 필기 목록 전체를 반환
    - UC-04 기본흐름 3a: WebSocket 재연결 후 스냅샷 수신으로 복원
    """
    redis = get_redis()
    
    # Redis에서 해당 방의 전체 필기 목록 조회
    key = f"snapshot:{room_id}"
    strokes = redis.lrange(key, 0, -1)
    
    if not strokes:
        return {
            "status": 200,
            "room_id": room_id,
            "strokes": [],
            "message": "필기 데이터가 없습니다."
        }
    
    # JSON 파싱
    import json
    parsed_strokes = [json.loads(s) for s in strokes]
    
    return {
        "status": 200,
        "room_id": room_id,
        "strokes": parsed_strokes,
        "message": f"총 {len(parsed_strokes)}개의 필기 데이터를 반환합니다."
    }