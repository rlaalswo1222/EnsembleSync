from celery import Celery

# Celery 앱 생성 + Redis 연동 설정
# broker: 작업 큐 (Redis)
# backend: 결과 저장 (Redis)
celery_app = Celery(
    "ensemblesync",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1"
)

celery_app.conf.update(
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    timezone="Asia/Seoul",
    enable_utc=True,
    task_track_started=True,  # processing 상태 추적
)