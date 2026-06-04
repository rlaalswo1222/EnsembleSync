import os
import json
import redis
import librosa
import numpy as np
from urllib.parse import urlparse
from celery_app import celery_app
from database import get_db


@celery_app.task(bind=True, name="tasks.bpm_analysis")
def bpm_analysis_task(self, job_id: str, audio_file_id: str):
    conn = get_db()
    cur = conn.cursor()

    try:
        # 1. room_id 조회
        cur.execute("SELECT room_id FROM analysis_job WHERE id = %s", (job_id,))
        row = cur.fetchone()
        if not row:
            raise Exception("BPM 분석 작업을 찾을 수 없습니다.")
        room_id = str(row[0])

        # 2. 같은 방의 가장 최근 완료된 separation job의 드럼 트랙 조회
        cur.execute("""
            SELECT st.file_url FROM separated_track st
            JOIN analysis_job aj ON st.job_id = aj.id
            WHERE aj.room_id = %s
              AND aj.job_type = 'separation'
              AND aj.status = 'done'
              AND st.track_type = 'drums'
            ORDER BY aj.completed_at DESC
            LIMIT 1
        """, (room_id,))
        row = cur.fetchone()
        if not row:
            raise Exception("드럼 트랙을 찾을 수 없습니다. 트랙 분리가 먼저 완료되어야 합니다.")

        file_url = row[0]
        url_path = urlparse(file_url).path
        local_audio_path = os.path.join(os.getcwd(), url_path.lstrip("/"))

        if not os.path.exists(local_audio_path):
            raise Exception(f"드럼 트랙 파일이 서버에 존재하지 않습니다: {local_audio_path}")

        # 3. librosa BPM 분석
        sr = 22050
        hop_length = 512
        y, sr = librosa.load(local_audio_path, sr=sr, mono=True)

        onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
        tempo, beat_frames = librosa.beat.beat_track(
            onset_envelope=onset_env, sr=sr, hop_length=hop_length,
            units="frames", trim=False,
        )
        base_bpm = float(np.asarray(tempo).squeeze())
        beat_times = librosa.frames_to_time(beat_frames, sr=sr, hop_length=hop_length)

        bpm_data_list = []
        times, bpms = [], []
        window_beats = 4
        max_bpm = min_bpm = avg_bpm = round(base_bpm, 1)

        if len(beat_times) >= 4:
            for i in range(window_beats, len(beat_times)):
                left = max(0, i - window_beats)
                beat_count = i - left
                window_duration = beat_times[i] - beat_times[left]
                if window_duration > 0:
                    times.append(beat_times[i])
                    bpms.append(60.0 * beat_count / window_duration)

            bpms = np.asarray(bpms)
            median_val = np.median(bpms)
            bpms = np.clip(bpms, median_val - 10, median_val + 10)

            if len(bpms) > 0:
                smoothed = np.empty_like(bpms)
                smoothed[0] = bpms[0]
                alpha = 0.55
                for i in range(1, len(bpms)):
                    smoothed[i] = alpha * bpms[i] + (1 - alpha) * smoothed[i - 1]
                bpms = smoothed

                max_bpm = round(float(np.max(bpms)), 1)
                min_bpm = round(float(np.min(bpms)), 1)
                avg_bpm = round(float(np.mean(bpms)), 1)

                for t, b in zip(times, bpms):
                    bpm_data_list.append({"time": round(float(t), 2), "bpm": round(float(b), 1)})

        # 4. 템포 변화 구간 — Flutter DeviationSection이 기대하는 {start, end, bpm} 형식
        deviation_sections = []
        chunk_size = 10.0
        if bpm_data_list:
            max_time = bpm_data_list[-1]["time"]
            for start_sec in range(0, int(max_time), int(chunk_size)):
                end_sec = float(start_sec + chunk_size)
                chunk_bpms = [
                    item["bpm"] for item in bpm_data_list
                    if start_sec <= item["time"] < end_sec
                ]
                if chunk_bpms:
                    chunk_avg = sum(chunk_bpms) / len(chunk_bpms)
                    if abs(chunk_avg - base_bpm) >= 3.0:
                        deviation_sections.append({
                            "start": float(start_sec),
                            "end": end_sec,
                            "bpm": round(chunk_avg, 1),
                        })

        # 5. DB 저장
        cur.execute("""
            INSERT INTO bpm_result
                (job_id, bpm_data, base_bpm, deviation_sections, max_bpm, min_bpm, avg_bpm)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
        """, (
            job_id,
            json.dumps(bpm_data_list),
            round(base_bpm, 1),
            json.dumps(deviation_sections),
            max_bpm, min_bpm, avg_bpm,
        ))
        cur.execute(
            "UPDATE analysis_job SET status = 'done', completed_at = now() WHERE id = %s",
            (job_id,)
        )
        conn.commit()

        # 6. WebSocket 푸시
        redis_client = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
        redis_client.publish(f"room_{room_id}", json.dumps({
            "type": "bpm_analyzed",
            "job_id": job_id,
            "base_bpm": round(base_bpm, 1),
        }))

        return {"status": "success", "job_id": job_id, "base_bpm": base_bpm}

    except Exception as e:
        conn.rollback()
        cur.execute("UPDATE analysis_job SET status = 'failed' WHERE id = %s", (job_id,))
        conn.commit()
        raise Exception(f"BPM 분석 중 오류 발생: {e}")

    finally:
        cur.close()
        conn.close()
