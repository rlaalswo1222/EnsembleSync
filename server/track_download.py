from fastapi import APIRouter, UploadFile, File, Form
from fastapi.responses import FileResponse
import psycopg2.extras
from database import get_db
from celery_app import celery_app
from config import (
    MAX_AUDIO_MB,
    REDIS_HOST,
    REDIS_PORT,
    save_upload_limited,
    local_upload_path,
    normalize_public_url,
    public_url,
    touch_room,
)
import uuid
import os
import json
import redis

router = APIRouter()

ALLOWED_AUDIO_EXTENSIONS = {'mp3', 'wav', 'flac', 'm4a'}
redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, decode_responses=True)


def publish_room_event(room_id: str, message: dict):
    try:
        redis_client.publish(f"room_{room_id}", json.dumps(message))
    except Exception:
        pass

@router.post("/api/track/separate")
async def request_track_separation(
    room_id: str = Form(...),
    file: UploadFile = File(...)
):
    conn = None
    file_path = None
    try:
        ext = file.filename.split('.')[-1].lower()
        if ext not in ALLOWED_AUDIO_EXTENSIONS:
            return {"status": 400, "message": f"지원하지 않는 오디오 형식입니다. 허용 형식: {', '.join(ALLOWED_AUDIO_EXTENSIONS)}"}

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute("SELECT id FROM room WHERE id = %s", (room_id,))
        if not cur.fetchone():
            return {"status": 404, "message": "존재하지 않는 방입니다."}

        audio_id = str(uuid.uuid4())
        save_dir = f"uploads/audio/{room_id}"
        os.makedirs(save_dir, exist_ok=True)
        file_path = f"{save_dir}/{audio_id}.{ext}"

        if not save_upload_limited(
            file.file, file_path, MAX_AUDIO_MB * 1024 * 1024
        ):
            file_path = None  # 이미 지워졌다
            return {
                "status": 413,
                "message": f"파일이 너무 큽니다. {MAX_AUDIO_MB}MB 이하만 올릴 수 있습니다.",
            }

        # DB 에는 상대경로로 저장한다 (서버 주소가 바뀌어도 레코드 수정 불필요)
        file_url = f"/uploads/audio/{room_id}/{audio_id}.{ext}"
        cur.execute(
            "INSERT INTO audio_file (id, room_id, file_type, file_url, purpose, uploaded_at) VALUES (%s, %s, %s, %s, 'separation', now())",
            (audio_id, room_id, ext, file_url)
        )

        job_id = str(uuid.uuid4())
        cur.execute(
            "INSERT INTO analysis_job (id, audio_file_id, room_id, job_type, status, requested_at) VALUES (%s, %s, %s, 'separation', 'pending', now())",
            (job_id, audio_id, room_id)
        )
        conn.commit()

        publish_room_event(room_id, {
            "type": "audio_uploaded",
            "payload": {
                "room_id": room_id,
                "audio_file_id": audio_id,
                "file_url": public_url(file_url),
                "filename": file.filename,
                "purpose": "separation",
            },
        })

        task = celery_app.send_task(
            "separate_audio_task",
            args=[file_path, room_id, job_id],
            queue="separation",
        )
        cur.execute("UPDATE analysis_job SET celery_task_id = %s WHERE id = %s", (task.id, job_id))
        touch_room(cur, room_id)
        conn.commit()
        cur.close()

        publish_room_event(room_id, {
            "type": "analysis_started",
            "payload": {
                "room_id": room_id,
                "job_id": job_id,
                "job_type": "separation",
                "audio_file_id": audio_id,
            },
        })

        return {
            "status": 202,
            "job_id": job_id,
            "message": "트랙 분리 작업이 백그라운드에서 시작되었습니다. 완료 시 실시간으로 알림을 보냅니다."
        }
    except Exception as e:
        if conn:
            conn.rollback()
        if file_path and os.path.exists(file_path):
            os.remove(file_path)
        return {"status": 500, "message": f"트랙 분리 요청 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()

@router.get("/api/track/{job_id}/list")
async def get_track_list(job_id: str):
    """분리 결과 조회.

    분리가 끝났다는 알림은 Redis pub/sub 으로 나가는데, 그건 재전송이 없다.
    앱의 WebSocket 이 잠깐이라도 끊겨 있으면 그 사이 지나간 알림은 영영
    사라지고, 앱은 끝난 줄 모른 채 계속 기다리게 된다.

    그래서 이 API 는 알림에 실려 나가는 것과 같은 것을 돌려준다. 앱이
    "그래서 어떻게 됐냐"고 물어볼 수 있어야 한다.

    - status: 진행 상태 (pending / done / failed)
    - tracks: 원본 wav 주소
    - streams: 재생용 mp3 주소 (변환에 실패한 트랙은 빠진다)
    - analysis_url: 파형·키·코드 분석 결과
    """
    conn = None
    try:
        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        cur.execute(
            "SELECT id, room_id, status FROM analysis_job WHERE id = %s",
            (job_id,)
        )
        job = cur.fetchone()
        if not job:
            return {"status": 404, "message": "존재하지 않는 작업입니다."}

        # 아직 도는 중이어도 200 으로 답한다. 앱은 이 값을 보고 계속 기다릴지
        # 결정하면 된다. 400 으로 던지면 오류인지 진행 중인지 구분이 어렵다.
        if job['status'] != 'done':
            return {
                "status": 200,
                "job_id": job_id,
                "job_status": job['status'],
                "tracks": [],
            }

        cur.execute(
            "SELECT id, track_type, file_url, created_at FROM separated_track WHERE job_id = %s",
            (job_id,)
        )
        tracks = cur.fetchall()
        cur.close()

        # 재생용 mp3 는 wav 와 같은 자리에 확장자만 다르게 있다. DB 에 따로
        # 담지 않으므로 파일이 실제로 있는지 보고 넣는다.
        streams = {}
        for t in tracks:
            mp3_rel = os.path.splitext(t['file_url'])[0] + ".mp3"
            try:
                if os.path.exists(local_upload_path(mp3_rel)):
                    streams[t['track_type']] = normalize_public_url(mp3_rel)
            except Exception:
                pass

        analysis_rel = f"/uploads/separated/{job_id}/analysis.json"
        analysis_url = None
        try:
            if os.path.exists(local_upload_path(analysis_rel)):
                analysis_url = normalize_public_url(analysis_rel)
        except Exception:
            pass

        return {
            "status": 200,
            "job_id": job_id,
            "job_status": job['status'],
            "room_id": str(job['room_id']),
            "tracks": [
                {
                    "track_id": str(t['id']),
                    "track_type": t['track_type'],
                    "file_url": normalize_public_url(t['file_url']),
                    "created_at": str(t['created_at'])
                }
                for t in tracks
            ],
            "streams": streams,
            "analysis_url": analysis_url,
        }
    except Exception as e:
        return {"status": 500, "message": f"트랙 목록 조회 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()

@router.get("/api/track/{job_id}/download/{track_type}")
async def download_track(job_id: str, track_type: str):
    """
    분리 트랙 다운로드 API
    - UC-13, FR-10
    - track_type: vocals / drums / bass / guitar
    """
    conn = None
    try:
        ALLOWED_TRACK_TYPES = {'vocals', 'drums', 'bass', 'other'}
        if track_type not in ALLOWED_TRACK_TYPES:
            return {
                "status": 400,
                "message": f"지원하지 않는 트랙 타입입니다. 허용 값: {', '.join(ALLOWED_TRACK_TYPES)}"
            }

        conn = get_db()
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(
            "SELECT file_url FROM separated_track WHERE job_id = %s AND track_type = %s",
            (job_id, track_type)
        )
        track = cur.fetchone()
        cur.close()

        if not track:
            return {"status": 404, "message": "해당 트랙을 찾을 수 없습니다."}

        # 파일 경로 추출
        file_url = track['file_url']
        file_path = local_upload_path(file_url)

        if not os.path.exists(file_path):
            return {"status": 404, "message": "파일이 서버에 존재하지 않습니다."}

        return FileResponse(
            path=file_path,
            filename=f"{track_type}.wav",
            media_type="audio/wav"
        )
    except Exception as e:
        return {"status": 500, "message": f"트랙 다운로드 중 오류가 발생했습니다: {str(e)}"}
    finally:
        if conn:
            conn.close()
