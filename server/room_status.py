"""방의 보관 상태 조회와 연장.

기한이 지나면 방이 통째로 사라진다. 사용자에게 그 사실이 보이지 않으면
어느 날 갑자기 방을 잃은 것이 된다. 언제 사라지는지 알려주고, 더 두고
싶으면 미룰 수 있게 한다.
"""
import os

import psycopg2.extras
from fastapi import APIRouter

from config import (
    ROOM_INACTIVE_DAYS,
    ROOM_WARN_WITHIN_DAYS,
    SEPARATED_DIR,
    local_upload_path,
)
from database import get_db

router = APIRouter()


def _dir_size(path: str) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


@router.get("/api/room/{room_id}/status")
async def get_room_status(room_id: str):
    """이 방이 언제 정리되는지, 지금 얼마나 쓰고 있는지."""
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            """
            SELECT name, room_code, created_at, last_active_at,
                   EXTRACT(EPOCH FROM (
                       last_active_at + make_interval(days => %s) - now()
                   )) / 86400 AS days_left
            FROM room WHERE id = %s
            """,
            (ROOM_INACTIVE_DAYS, room_id),
        )
        room = cur.fetchone()
        if not room:
            return {"status": 404, "message": "존재하지 않는 방입니다."}

        # 이 방이 차지하는 용량 전부. 기한이 지나면 방째로 사라지므로
        # 분리 결과만 세면 실제로 없어지는 양보다 작게 보인다.
        cur.execute(
            """
            SELECT DISTINCT st.job_id::text AS job_id
            FROM separated_track st
            JOIN analysis_job aj ON aj.id = st.job_id
            WHERE aj.room_id = %s
            """,
            (room_id,),
        )
        used = 0
        job_count = 0
        for row in cur.fetchall():
            path = os.path.join(SEPARATED_DIR, row["job_id"])
            if os.path.isdir(path):
                used += _dir_size(path)
                job_count += 1

        for table in ("audio_file", "score"):
            cur.execute(
                f"SELECT file_url FROM {table} WHERE room_id = %s", (room_id,)
            )
            for row in cur.fetchall():
                try:
                    fp = local_upload_path(row["file_url"])
                    if os.path.exists(fp):
                        used += os.path.getsize(fp)
                except Exception:
                    pass
        cur.close()

        days_left = int(room["days_left"])
        return {
            "status": 200,
            "room_id": room_id,
            "room_name": room["name"],
            "last_active_at": str(room["last_active_at"]),
            "days_left": days_left,
            "inactive_days": ROOM_INACTIVE_DAYS,
            # 앱은 이 값만 보고 안내를 띄울지 정하면 된다.
            "warn": days_left <= ROOM_WARN_WITHIN_DAYS,
            "separated_jobs": job_count,
            # 방이 사라질 때 함께 없어지는 전체 용량.
            "total_mb": round(used / 1024 / 1024, 1),
        }
    except Exception as e:
        return {"status": 500, "message": f"방 상태 조회 실패: {e}"}
    finally:
        if conn:
            conn.close()


@router.post("/api/room/{room_id}/keep")
async def keep_room(room_id: str):
    """정리 기한을 지금부터 다시 센다.

    별도의 '보관' 플래그를 두지 않고 활동 시각만 갱신한다. 상태가 하나면
    정리 규칙도 하나로 끝나고, 플래그를 켠 방이 영원히 남는 일도 없다.
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute(
            "UPDATE room SET last_active_at = now() WHERE id = %s", (room_id,)
        )
        if cur.rowcount == 0:
            return {"status": 404, "message": "존재하지 않는 방입니다."}
        conn.commit()
        cur.close()
        return {
            "status": 200,
            "days_left": ROOM_INACTIVE_DAYS,
            "message": f"{ROOM_INACTIVE_DAYS}일 더 보관합니다.",
        }
    except Exception as e:
        if conn:
            conn.rollback()
        return {"status": 500, "message": f"보관 연장 실패: {e}"}
    finally:
        if conn:
            conn.close()
