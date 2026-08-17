# FastAPI API 서버 이미지
# 무거운 분석 작업은 Celery 워커가 맡으므로 여기엔 torch/demucs 를 넣지 않는다.
# 파이썬 버전은 EC2 운영 환경(3.14)과 맞춘다.
FROM python:3.14-slim

WORKDIR /app

# 의존성을 코드보다 먼저 설치한다.
# 코드만 바뀌었을 때 이 레이어를 캐시에서 재사용하기 위함.
COPY requirements-api.txt .
RUN pip install --no-cache-dir -r requirements-api.txt

# 애플리케이션 코드
COPY . .

# root 로 실행하지 않는다. uid 를 1000 으로 맞춰 호스트의 ubuntu 유저가
# 소유한 uploads 볼륨에 그대로 읽고 쓸 수 있게 한다.
RUN useradd -u 1000 -m app && chown -R app:app /app
USER app

EXPOSE 8000

# 0.0.0.0 으로 열어야 컨테이너 밖에서 접속할 수 있다.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
