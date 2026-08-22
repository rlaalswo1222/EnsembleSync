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
    normalize_public_url,
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


@router.get("/api/room/{room_id}/latest")
async def get_room_latest(room_id: str):
    """이 방에 이미 있는 음원과 분석 결과.

    악보와 필기는 방에 들어올 때 API 로 불러오는데, 음원과 분석 결과는
    WebSocket 알림으로만 왔다. 알림은 지나가면 끝이라 나중에 들어온 사람은
    빈 화면을 본다. 서버에는 멀쩡히 있는데 볼 길이 없었다.

    분리 완료 알림과 같은 모양으로 돌려준다. 앱이 두 경로를 같은 코드로
    처리할 수 있어야 한다.
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        result = {"status": 200, "room_id": room_id}

        # 가장 최근에 올라온 음원
        cur.execute(
            """
            SELECT id::text, file_url, file_type
            FROM audio_file WHERE room_id = %s
            ORDER BY uploaded_at DESC LIMIT 1
            """,
            (room_id,),
        )
        audio = cur.fetchone()
        if audio:
            result["audio"] = {
                "audio_file_id": audio["id"],
                "file_url": normalize_public_url(audio["file_url"]),
                "file_type": audio["file_type"],
            }

        # 가장 최근에 끝난 분리
        cur.execute(
            """
            SELECT aj.id::text AS job_id
            FROM analysis_job aj
            WHERE aj.room_id = %s AND aj.job_type = 'separation'
              AND aj.status = 'done'
            ORDER BY aj.completed_at DESC LIMIT 1
            """,
            (room_id,),
        )
        job = cur.fetchone()
        if job:
            job_id = job["job_id"]
            cur.execute(
                "SELECT track_type, file_url FROM separated_track "
                "WHERE job_id = %s",
                (job_id,),
            )
            tracks, streams = {}, {}
            for row in cur.fetchall():
                wav = row["file_url"]
                tracks[row["track_type"]] = normalize_public_url(wav)
                mp3 = os.path.splitext(wav)[0] + ".mp3"
                try:
                    if os.path.exists(local_upload_path(mp3)):
                        streams[row["track_type"]] = normalize_public_url(mp3)
                except Exception:
                    pass

            if tracks:
                analysis_rel = f"/uploads/separated/{job_id}/analysis.json"
                analysis_url = None
                try:
                    if os.path.exists(local_upload_path(analysis_rel)):
                        analysis_url = normalize_public_url(analysis_rel)
                except Exception:
                    pass
                result["separation"] = {
                    "room_id": room_id,
                    "job_id": job_id,
                    "tracks": tracks,
                    "streams": streams,
                    "analysis_url": analysis_url,
                }

        # 가장 최근에 끝난 BPM
        cur.execute(
            """
            SELECT id::text FROM analysis_job
            WHERE room_id = %s AND job_type = 'bpm' AND status = 'done'
            ORDER BY completed_at DESC LIMIT 1
            """,
            (room_id,),
        )
        bpm = cur.fetchone()
        if bpm:
            result["bpm_job_id"] = bpm["id"]

        cur.close()
        return result
    except Exception as e:
        return {"status": 500, "message": f"방 자료 조회 실패: {e}"}
    finally:
        if conn:
            conn.close()
