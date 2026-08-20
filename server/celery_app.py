from celery import Celery
from celery.schedules import crontab

from config import REDIS_HOST, REDIS_PORT

# Celery 앱 생성 + Redis 연동 설정
# broker: 작업 큐 (Redis)
# backend: 결과 저장 (Redis)
celery_app = Celery(
    "ensemblesync",
    broker=f"redis://{REDIS_HOST}:{REDIS_PORT}/0",
    backend=f"redis://{REDIS_HOST}:{REDIS_PORT}/1"
)

celery_app.conf.update(
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    timezone="Asia/Seoul",
    enable_utc=True,
    task_track_started=True,  # processing 상태 추적
    # 워커가 정리 태스크를 인식하도록 모듈을 함께 로드한다.
    imports=("cleanup",),
)

# 분리 결과물 정리는 매일 새벽 4시에 bpm 큐로 보낸다.
# (separation 워커는 무거운 작업 중일 수 있어 가벼운 쪽에 맡긴다)
celery_app.conf.beat_schedule = {
    "cleanup-separated-daily": {
        "task": "tasks.cleanup_separated",
        "schedule": crontab(hour=4, minute=0),
        "options": {"queue": "bpm"},
    },
}