"""분리 결과물(uploads/separated) 정리.

분리 트랙은 작업당 약 18MB 씩 쌓이는데 지우는 로직이 없어 디스크를 계속
잠식한다. 원본 음원만 있으면 다시 만들 수 있으므로 오래된 것부터 지운다.

세 가지를 정리한다.
  1) 끊어진 레코드 — DB 에는 있는데 파일이 없는 것
  2) 보관 기간이 지난 결과물 — 단 방마다 최신 1건은 남긴다
  3) 고아 디렉터리 — DB 레코드 없이 남은 것 (실패한 작업이 남긴다)

bpm_analyze 는 "그 방의 가장 최근 분리"의 드럼 트랙을 쓴다. 그래서 방마다
최신 1건은 기간이 지나도 남긴다(2). 다만 파일이 이미 없는 레코드는 남겨봐야
BPM 이 그걸 최신으로 골랐다가 실패하므로 나이와 무관하게 지운다(1).
"""
import os
import shutil
from datetime import datetime, timedelta

from celery_app import celery_app
from database import get_db

SEPARATED_DIR = "uploads/separated"
RETENTION_DAYS = int(os.getenv("SEPARATED_RETENTION_DAYS", "30"))
ORPHAN_GRACE_HOURS = 24  # 진행 중인 작업을 지우지 않도록 하루는 봐준다


def _job_dir(job_id: str) -> str:
    return os.path.join(SEPARATED_DIR, job_id)


def _dir_size(path: str) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def _dangling(cur):
    """레코드는 있는데 파일이 없는 작업. 이미 404 가 나는 상태다."""
    cur.execute("SELECT DISTINCT job_id::text FROM separated_track")
    return [j for (j,) in cur.fetchall() if not os.path.isdir(_job_dir(j))]


def _expired(cur, retention_days: int):
    """기간이 지난 작업. 파일이 살아있는 것 중에서만 고르고,
    방마다 최신 1건은 제외한다."""
    cur.execute(
        """
        SELECT DISTINCT st.job_id::text, aj.room_id::text, aj.completed_at
        FROM separated_track st
        JOIN analysis_job aj ON aj.id = st.job_id
        WHERE aj.completed_at IS NOT NULL
        ORDER BY aj.room_id::text, aj.completed_at DESC
        """
    )
    rows = [r for r in cur.fetchall() if os.path.isdir(_job_dir(r[0]))]

    cutoff = datetime.now() - timedelta(days=retention_days)
    seen_rooms, expired = set(), []
    for job_id, room_id, completed_at in rows:
        if room_id not in seen_rooms:   # 방의 최신 1건은 보존
            seen_rooms.add(room_id)
            continue
        if completed_at < cutoff:
            expired.append(job_id)
    return expired


def _orphans(cur):
    """DB 에 없는 디렉터리. 최근 것은 진행 중일 수 있어 제외한다."""
    if not os.path.isdir(SEPARATED_DIR):
        return []
    cur.execute("SELECT DISTINCT job_id::text FROM separated_track")
    known = {j for (j,) in cur.fetchall()}
    cutoff = datetime.now() - timedelta(hours=ORPHAN_GRACE_HOURS)
    out = []
    for name in os.listdir(SEPARATED_DIR):
        path = _job_dir(name)
        if not os.path.isdir(path) or name in known:
            continue
        if datetime.fromtimestamp(os.path.getmtime(path)) < cutoff:
            out.append(name)
    return out


@celery_app.task(name="tasks.cleanup_separated")
def cleanup_separated(retention_days: int = None, dry_run: bool = False):
    days = RETENTION_DAYS if retention_days is None else int(retention_days)
    conn = get_db()
    cur = conn.cursor()
    try:
        dangling = _dangling(cur)
        expired = _expired(cur, days)
        orphans = _orphans(cur)

        freed = 0
        for job_id in expired + orphans:
            path = _job_dir(job_id)
            if os.path.isdir(path):
                freed += _dir_size(path)
                if not dry_run:
                    shutil.rmtree(path, ignore_errors=True)

        rows = dangling + expired
        if rows and not dry_run:
            # 파일이 없어졌으니 레코드도 지운다. 남기면 앱에서 404 가 난다.
            cur.execute(
                "DELETE FROM separated_track WHERE job_id::text = ANY(%s)", (rows,)
            )
            conn.commit()

        return {
            "status": "success",
            "dry_run": dry_run,
            "retention_days": days,
            "dangling_records": len(dangling),
            "expired_jobs": len(expired),
            "orphan_dirs": len(orphans),
            "freed_mb": round(freed / 1024 / 1024, 1),
        }
    except Exception as e:
        conn.rollback()
        return {"status": "error", "error_message": str(e)}
    finally:
        cur.close()
        conn.close()
