"""분리 결과물(uploads/separated) 정리.

분리 트랙은 작업당 약 18MB 씩 쌓이는데 지우는 로직이 없어 디스크를 계속
잠식한다. 원본 음원만 있으면 다시 만들 수 있으므로 오래된 것부터 지운다.

여섯 가지를 정리한다.
  1) 끊어진 레코드 — DB 에는 있는데 파일이 없는 것
  2) 보관 기간이 지난 결과물 — 단 방마다 최신 1건은 남긴다
  3) 고아 디렉터리 — DB 레코드 없이 남은 것 (실패한 작업이 남긴다)
  4) 멈춘 작업 — pending 인 채로 오래 남은 것
  5) 빈 방 — 만들고 아무것도 하지 않은 채 버려진 것
  6) 쉬는 방 — 오래 아무 일도 없던 방. 통째로 지운다
  7) 고아 파일 — 음원·악보 폴더에 있는데 DB 가 모르는 것

bpm_analyze 는 "그 방의 가장 최근 분리"의 드럼 트랙을 쓴다. 그래서 방마다
최신 1건은 기간이 지나도 남긴다(2). 다만 파일이 이미 없는 레코드는 남겨봐야
BPM 이 그걸 최신으로 골랐다가 실패하므로 나이와 무관하게 지운다(1).
"""
import os
import shutil
from datetime import datetime, timedelta

import disk
from celery_app import celery_app
from config import (
    ROOM_INACTIVE_DAYS,
    SEPARATED_DIR,
    SEPARATED_RETENTION_DAYS,
    local_upload_path,
)
from database import get_db

# 정리 기준을 "작업이 만들어진 날짜" 가 아니라 "방이 마지막으로 쓰인 날짜"
# 로 잡는다. 40일째 계속 쓰고 있는 방의 결과가 사라지면 안 되고, 반대로
# 만든 지 하루 만에 버려진 방을 오래 들고 있을 이유도 없다.
RETENTION_DAYS = SEPARATED_RETENTION_DAYS
ORPHAN_GRACE_HOURS = 24  # 진행 중인 작업을 지우지 않도록 하루는 봐준다

# 멈춘 작업을 판정하는 기준.
#
# 작업 도중 워커가 죽으면(배포로 컨테이너가 재시작되는 경우가 대부분이다)
# 실패 처리 코드가 실행될 기회 자체가 없어서 status 가 그대로 남는다.
#
# 대기와 실행을 반드시 구분해야 한다. 둘 다 pending 으로 두고 시간만 보면,
# 사용자가 몰려 큐가 밀렸을 때 **정직하게 기다리던 작업까지 실패로 바뀐다**.
# 서버가 한 번에 한 곡밖에 못 돌리므로 큐가 몇 시간씩 밀리는 것은 정상이다.
#
#   processing  워커가 집어들었는데 안 끝남 → 죽은 것이 거의 확실
#   pending     아직 아무도 안 가져감 → 큐 대기일 수 있어 넉넉히 본다
#
# 가장 오래 걸린 분리가 7분이었다.
STALE_PROCESSING_HOURS = 2
STALE_PENDING_HOURS = 24

# 만들고 이만큼 아무것도 안 한 방은 지운다.
#
# 방 코드는 여섯 자리뿐이다. 만들다 만 방이 계속 쌓이면 언젠가 뽑을 코드가
# 마른다. 디스크보다 이쪽이 먼저 걸릴 수 있다.
#
# 넉넉히 잡는다. 방을 만들어 두고 다음 날 곡을 올리는 것은 이상한 일이
# 아니다. 반대로 하루 넘게 아무 일도 없었다면 잘못 만든 방일 가능성이 크다.
EMPTY_ROOM_HOURS = int(os.getenv("EMPTY_ROOM_HOURS", "48"))


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
    """지울 분리 결과를 고른다.

    방이 살아 있는지에 따라 기준이 다르다.

    쉬는 방은 여기서 다루지 않는다. [_delete_inactive_rooms] 가 방과 함께
    통째로 지운다. 같은 일을 두 곳에서 하면 어느 쪽이 지웠는지 헷갈린다.

    최신 1건을 남기는 이유는 BPM 분석이 "그 방의 가장 최근 분리" 의 드럼
    트랙을 쓰기 때문이다. 쉬는 방에는 BPM 을 돌릴 일이 없으므로 남길
    이유도 없다.

    원본 음원은 건드리지 않는다. 전체 사용량의 12% 뿐이고, 사용자가 올린
    것이라 다시 만들 수 없다. 분리 결과는 원본만 있으면 다시 만든다.
    """
    cur.execute(
        """
        SELECT DISTINCT st.job_id::text, aj.room_id::text, aj.completed_at,
               r.last_active_at
        FROM separated_track st
        JOIN analysis_job aj ON aj.id = st.job_id
        JOIN room r ON r.id = aj.room_id
        WHERE aj.completed_at IS NOT NULL
        ORDER BY aj.room_id::text, aj.completed_at DESC
        """
    )
    rows = [r for r in cur.fetchall() if os.path.isdir(_job_dir(r[0]))]

    job_cutoff = datetime.now() - timedelta(days=retention_days)
    room_cutoff = datetime.now() - timedelta(days=ROOM_INACTIVE_DAYS)

    seen_rooms, expired = set(), []
    for job_id, room_id, completed_at, last_active_at in rows:
        if last_active_at < room_cutoff:
            continue                    # 방째로 지워질 것이라 손대지 않는다
        if room_id not in seen_rooms:   # 쓰는 방의 최신 1건은 보존
            seen_rooms.add(room_id)
            continue
        if completed_at < job_cutoff:
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


def _fail_stale_jobs(cur) -> int:
    """멈춘 채 남은 작업을 failed 로 정리하고 그 건수를 돌려준다.

    지우지 않고 failed 로 표시만 한다. 사용자가 무엇을 시도했는지는 기록으로
    남아야 하고, 나중에 작업 목록을 보여줄 때 진행 중인 것과 섞이지만
    않으면 된다.
    """
    cur.execute(
        """
        UPDATE analysis_job
        SET status = 'failed', completed_at = now()
        WHERE (status = 'processing'
                 AND requested_at < now() - make_interval(hours => %s))
           OR (status = 'pending'
                 AND requested_at < now() - make_interval(hours => %s))
        """,
        (STALE_PROCESSING_HOURS, STALE_PENDING_HOURS),
    )
    return cur.rowcount


def _delete_empty_rooms(cur) -> int:
    """만들고 아무것도 하지 않은 방을 지운다.

    "비었다" 는 음원도 악보도 분석 기록도 없다는 뜻이다. 참가자는 세지
    않는다 — 빈 방에 들어갔다 나온 것뿐이라 지울 이유가 되지 않는다.

    room_participant, score, audio_file 은 방을 지우면 함께 지워진다.
    analysis_job 에는 ON DELETE CASCADE 가 없는데, 여기서는 그것이
    안전장치로 작동한다. 분석 기록이 있는 방을 실수로 골랐다면 삭제가
    실패하고, 그 방은 그대로 남는다.
    """
    cur.execute(
        """
        DELETE FROM room r
        WHERE r.created_at < now() - make_interval(hours => %s)
          AND r.last_active_at < now() - make_interval(hours => %s)
          AND NOT EXISTS (SELECT 1 FROM audio_file   a WHERE a.room_id = r.id)
          AND NOT EXISTS (SELECT 1 FROM score        s WHERE s.room_id = r.id)
          AND NOT EXISTS (SELECT 1 FROM analysis_job j WHERE j.room_id = r.id)
        """,
        (EMPTY_ROOM_HOURS, EMPTY_ROOM_HOURS),
    )
    return cur.rowcount


def _remove_upload(file_url: str) -> int:
    """업로드 파일 하나를 지우고 그 크기를 돌려준다."""
    try:
        path = local_upload_path(file_url)
    except Exception:
        return 0
    try:
        size = os.path.getsize(path)
        os.remove(path)
        return size
    except OSError:
        return 0


def _orphan_uploads(cur) -> tuple:
    """음원·악보 폴더에서 DB 가 모르는 파일을 지운다. (개수, 바이트)

    분리 결과 폴더에는 고아 청소가 있었는데 이 둘에는 없었다. 실제로 아홉
    개가 쌓여 있었다 — 파일은 저장됐는데 그 뒤 DB 쓰기가 실패한 흔적으로
    보인다.

    막 올라온 파일은 건드리지 않는다. 저장과 DB 쓰기 사이의 짧은 순간에
    청소가 돌면 멀쩡한 업로드를 지우게 된다.
    """
    known = set()
    for table in ("audio_file", "score"):
        cur.execute(f"SELECT file_url FROM {table}")
        for (file_url,) in cur.fetchall():
            if not file_url:
                continue
            try:
                known.add(os.path.normpath(local_upload_path(file_url)))
            except Exception:
                pass

    cutoff = datetime.now() - timedelta(hours=ORPHAN_GRACE_HOURS)
    count, freed = 0, 0
    for folder in ("uploads/audio", "uploads/scores"):
        if not os.path.isdir(folder):
            continue
        for root, _, files in os.walk(folder):
            for name in files:
                path = os.path.normpath(os.path.join(root, name))
                if path in known:
                    continue
                try:
                    if datetime.fromtimestamp(os.path.getmtime(path)) > cutoff:
                        continue
                    freed += os.path.getsize(path)
                    os.remove(path)
                    count += 1
                except OSError:
                    pass
    return count, freed


def _delete_inactive_rooms(cur):
    """오래 쉰 방을 통째로 지운다. (지운 방 수, 비운 바이트)

    방 행만 지우면 디스크의 파일은 고아로 남는다. DB 의 CASCADE 는 행만
    따라 지울 뿐 파일은 모른다. 그래서 파일을 먼저 훑어 지우고 나서
    레코드를 지운다.

    analysis_job 에는 room 으로부터의 ON DELETE CASCADE 가 없다. 남겨두면
    방 삭제가 외래키에 막히므로 먼저 지운다. separated_track 과 bpm_result
    는 analysis_job 을 따라 지워지고, audio_file 과 score, participant 는
    room 을 따라 지워진다.
    """
    cur.execute(
        """
        SELECT id::text FROM room
        WHERE last_active_at < now() - make_interval(days => %s)
        """,
        (ROOM_INACTIVE_DAYS,),
    )
    room_ids = [r[0] for r in cur.fetchall()]
    if not room_ids:
        return 0, 0

    freed = 0

    # 분리 결과 폴더
    cur.execute(
        "SELECT id::text FROM analysis_job WHERE room_id::text = ANY(%s)",
        (room_ids,),
    )
    for (job_id,) in cur.fetchall():
        path = _job_dir(job_id)
        if os.path.isdir(path):
            freed += _dir_size(path)
            shutil.rmtree(path, ignore_errors=True)

    # 원본 음원과 악보
    for table in ("audio_file", "score"):
        cur.execute(
            f"SELECT file_url FROM {table} WHERE room_id::text = ANY(%s)",
            (room_ids,),
        )
        for (file_url,) in cur.fetchall():
            if file_url:
                freed += _remove_upload(file_url)

    cur.execute(
        "DELETE FROM analysis_job WHERE room_id::text = ANY(%s)", (room_ids,)
    )
    cur.execute("DELETE FROM room WHERE id::text = ANY(%s)", (room_ids,))
    return len(room_ids), freed


@celery_app.task(name="tasks.cleanup_separated")
def cleanup_separated(retention_days: int = None, dry_run: bool = False):
    days = RETENTION_DAYS if retention_days is None else int(retention_days)

    # 디스크가 차오르면 기준을 좁힌다.
    #
    # 평소 기준은 "쓰기 좋게" 정한 값이다. 공간이 없으면 그 편의보다 서비스가
    # 도는 것이 먼저다. 절반으로 줄이되 하루 밑으로는 내리지 않는다. 오늘
    # 만든 것까지 지우면 쓰는 도중에 사라진다.
    tight = disk.is_tight()
    if tight:
        days = max(1, days // 2)
    conn = get_db()
    cur = conn.cursor()
    try:
        dangling = _dangling(cur)
        expired = _expired(cur, days)
        orphans = _orphans(cur)
        stale = 0 if dry_run else _fail_stale_jobs(cur)
        empty_rooms = 0 if dry_run else _delete_empty_rooms(cur)
        dead_rooms, room_freed = (0, 0) if dry_run else _delete_inactive_rooms(cur)
        # 방 삭제 뒤에 돈다. 그래야 방이 남긴 것까지 같은 회차에 걷힌다.
        orphan_files, orphan_freed = (0, 0) if dry_run else _orphan_uploads(cur)

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
        if not dry_run:
            # 지울 파일이 없어도 멈춘 작업 정리는 반영되어야 한다.
            conn.commit()

        return {
            "status": "success",
            "dry_run": dry_run,
            "retention_days": days,
            "disk_tight": tight,
            "disk": disk.usage(),
            "room_inactive_days": ROOM_INACTIVE_DAYS,
            "dangling_records": len(dangling),
            "expired_jobs": len(expired),
            "orphan_dirs": len(orphans),
            "stale_jobs_failed": stale,
            "empty_rooms_deleted": empty_rooms,
            "inactive_rooms_deleted": dead_rooms,
            "orphan_files_deleted": orphan_files,
            "freed_mb": round(
                (freed + room_freed + orphan_freed) / 1024 / 1024, 1
            ),
        }
    except Exception as e:
        conn.rollback()
        return {"status": "error", "error_message": str(e)}
    finally:
        cur.close()
        conn.close()
