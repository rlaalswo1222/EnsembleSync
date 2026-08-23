"""기동할 때 스키마를 맞춘다.

ensemblesync_ddl.sql 은 docker-entrypoint-initdb.d 에 걸려 있어서 DB 를
처음 만들 때만 돈다. 이미 돌고 있는 DB 에는 아무 영향이 없다. 그래서
컬럼을 하나 더할 때마다 서버에 붙어 손으로 ALTER 를 쳐야 했고, 그걸
잊으면 배포는 성공했는데 API 만 터진다.

여기 적어두면 API 가 뜰 때 알아서 맞춘다. 전부 IF NOT EXISTS 라 몇 번을
돌려도 같은 결과가 나온다.

새로 만드는 DB 는 DDL 이 이미 갖춘 상태로 시작하므로 여기서는 전부
건너뛴다. 두 곳에 같은 내용이 있는 셈인데, DDL 은 '지금의 완성된 모습'
이고 이쪽은 '거기까지 가는 길' 이라 역할이 다르다.
"""
import logging

from database import get_db

log = logging.getLogger(__name__)

MIGRATIONS = [
    # 참가 토큰. 방 코드는 한 번 쓰는 초대장이고, 이후의 열쇠는 이것이다.
    "ALTER TABLE room_participant ADD COLUMN IF NOT EXISTS token TEXT",
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_participant_token "
    "ON room_participant(token)",
]


def run() -> None:
    """실패해도 서버는 뜬다.

    DB 가 아직 안 올라왔을 수도 있고, 권한이 모자랄 수도 있다. 그때
    API 를 통째로 죽이면 고칠 방법까지 함께 사라진다. 크게 남기고 넘어간다.
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor()
        for sql in MIGRATIONS:
            cur.execute(sql)
        conn.commit()
        cur.close()
        log.info("스키마 확인 완료 (%d건)", len(MIGRATIONS))
    except Exception as e:
        if conn:
            conn.rollback()
        log.error("스키마를 맞추지 못했습니다: %s", e)
    finally:
        if conn:
            conn.close()
