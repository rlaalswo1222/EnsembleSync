import os
import json
import librosa
import numpy as np
import redis
from celery import Celery
from database import get_db

redis_client = redis.Redis(host='localhost', port=6379, db=0, decode_responses=True)
celery_app = Celery("bpm_tasks", broker="redis://localhost:6379/0")

@celery_app.task(bind=True, name="tasks.bpm_analysis")
def bpm_analysis_task(self, job_id: str, room_id: str):
    conn = get_db()
    cur = conn.cursor()
    
    try:
        # ==========================================
        # 1. job_id로 분리된 드럼 트랙 경로 조회
        # ==========================================
        cur.execute("""
            SELECT file_url FROM separated_track 
            WHERE job_id = %s AND track_type = 'drums';
        """, (job_id,))
        row = cur.fetchone()
        
        if not row:
            raise Exception("해당 작업의 드럼 트랙을 찾을 수 없습니다.")
        
        file_url = row[0]
        filename = file_url.split("/")[-1]
        local_audio_path = os.path.join(os.getcwd(), "uploads", "separated", str(job_id), filename)
        
        if not os.path.exists(local_audio_path):
            raise Exception("드럼 트랙 파일이 서버에 존재하지 않습니다.")

        # ==========================================
        # 2. librosa로 전체 BPM, 구간별 BPM, 템포 이탈 분석
        # ==========================================
        sr = 22050
        hop_length = 512
        y, sr = librosa.load(local_audio_path, sr=sr, mono=True)
        
        onset_env = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop_length)
        tempo, beat_frames = librosa.beat.beat_track(
            onset_envelope=onset_env, sr=sr, hop_length=hop_length, units="frames", trim=False
        )
        
        base_bpm = float(np.asarray(tempo).squeeze())
        beat_times = librosa.frames_to_time(beat_frames, sr=sr, hop_length=hop_length)
        
        bpm_data_list = []
        window_beats = 4
        times = []
        bpms = []
        
        # 통계값 초기화 (비정상적인 오디오 방어 로직)
        max_bpm = min_bpm = avg_bpm = round(base_bpm, 1)
        
        if len(beat_times) >= 4:
            for i in range(window_beats, len(beat_times)):
                left = max(0, i - window_beats)
                beat_count = i - left
                window_duration = beat_times[i] - beat_times[left]
                if window_duration > 0:
                    bpm = 60.0 * beat_count / window_duration
                    times.append(beat_times[i])
                    bpms.append(bpm)
            
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
                
                # DB 추가용 최고, 최저, 평균 BPM 계산 로직 추가 (UI 화면용)
                max_bpm = round(float(np.max(bpms)), 1)
                min_bpm = round(float(np.min(bpms)), 1)
                avg_bpm = round(float(np.mean(bpms)), 1)
                
                for t, b in zip(times, bpms):
                    bpm_data_list.append({"time": round(float(t), 2), "bpm": round(float(b), 1)})

        # 템포 이탈 구간 분석
        deviation_sections = []
        chunk_size = 10.0 
        
        if len(bpm_data_list) > 0:
            max_time = bpm_data_list[-1]["time"]
            for start_sec in range(0, int(max_time), int(chunk_size)):
                end_sec = start_sec + chunk_size
                chunk_bpms = [item["bpm"] for item in bpm_data_list if start_sec <= item["time"] < end_sec]
                
                if chunk_bpms:
                    chunk_avg = sum(chunk_bpms) / len(chunk_bpms)
                    diff = chunk_avg - base_bpm
                    if abs(diff) >= 3.0:
                        deviation_sections.append({
                            "start": start_sec,
                            "end": end_sec,
                            "bpm_diff": round(diff, 1)
                        })

        # ==========================================
        # 3. 결과 DB 저장 (신규 컬럼 3개 추가)
        # ==========================================
        insert_bpm_query = """
            INSERT INTO bpm_result 
            (job_id, bpm_data, base_bpm, deviation_sections, max_bpm, min_bpm, avg_bpm)
            VALUES (%s, %s, %s, %s, %s, %s, %s);
        """
        cur.execute(insert_bpm_query, (
            job_id, 
            json.dumps(bpm_data_list), 
            round(base_bpm, 1), 
            json.dumps(deviation_sections),
            max_bpm,
            min_bpm,
            avg_bpm
        ))
        
        update_job_query = "UPDATE analysis_job SET status = 'done', completed_at = now() WHERE id = %s;"
        cur.execute(update_job_query, (job_id,))
        
        conn.commit()

        # ==========================================
        # 4. 분석 완료 시 WebSocket 푸시
        # ==========================================
        complete_msg = {
            "type": "BPM_ANALYSIS_COMPLETED",
            "job_id": job_id,
            "room_id": room_id,
            "base_bpm": round(base_bpm, 1),
            "max_bpm": max_bpm,
            "min_bpm": min_bpm,
            "avg_bpm": avg_bpm
        }
        redis_client.publish(f"room_{room_id}", json.dumps(complete_msg))

        return {"status": "success", "job_id": job_id, "base_bpm": base_bpm}

    except Exception as e:
        conn.rollback()
        cur.execute("UPDATE analysis_job SET status = 'failed' WHERE id = %s;", (job_id,))
        conn.commit()
        raise Exception(f"BPM 분석 중 오류 발생: {e}")
        
    finally:
        cur.close()
        conn.close()