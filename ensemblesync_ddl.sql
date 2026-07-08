-- ============================================================
-- EnsembleSync — PostgreSQL DDL
-- 소프트웨어공학 팀 프로젝트 | 4EVER팀
-- 기반: 요구분석서 v5 (FR-01~FR-12, NR-01~NR-07)
-- ============================================================

-- 확장 (UUID 생성)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- 1. Member (팀 멤버)
-- UC-01, UC-02
-- ============================================================
CREATE TABLE member (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    nickname    VARCHAR(50) NOT NULL,
    created_at  TIMESTAMP   NOT NULL DEFAULT now()
);

-- ============================================================
-- 2. Room (합주 방)
-- UC-01, FR-01, NR-05
-- ============================================================
CREATE TABLE room (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    room_code   VARCHAR(6)  NOT NULL UNIQUE,   -- 6자리 입장 코드 (NR-05)
    name        VARCHAR(100) NOT NULL,
    created_by  UUID        NOT NULL REFERENCES member(id),
    created_at  TIMESTAMP   NOT NULL DEFAULT now(),
    is_active   BOOLEAN     NOT NULL DEFAULT true
);

CREATE INDEX idx_room_code ON room(room_code);

-- ============================================================
-- 3. RoomParticipant (방 참여)
-- UC-02
-- ============================================================
CREATE TABLE room_participant (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id     UUID        NOT NULL REFERENCES room(id) ON DELETE CASCADE,
    member_id   UUID        NOT NULL REFERENCES member(id),
    joined_at   TIMESTAMP   NOT NULL DEFAULT now(),
    role        VARCHAR(20) NOT NULL DEFAULT 'member'
                CHECK (role IN ('leader', 'member')),
    UNIQUE (room_id, member_id)
);

-- ============================================================
-- 4. Score (악보)
-- UC-03, FR-01
-- ============================================================
CREATE TABLE score (
    id           UUID      PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id      UUID      NOT NULL REFERENCES room(id) ON DELETE CASCADE,
    uploaded_by  UUID      NOT NULL REFERENCES member(id),
    file_url     TEXT      NOT NULL,   -- S3/MinIO URL
    file_type    VARCHAR(10) NOT NULL
                 CHECK (file_type IN ('jpg', 'jpeg', 'png', 'pdf')),
    uploaded_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- ============================================================
-- 5. Annotation (필기)
-- UC-04, UC-05, FR-02, FR-03, FR-04
-- ============================================================
CREATE TABLE annotation (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    score_id     UUID        NOT NULL REFERENCES score(id) ON DELETE CASCADE,
    member_id    UUID        NOT NULL REFERENCES member(id),
    tool_type    VARCHAR(20) NOT NULL
                 CHECK (tool_type IN ('pen', 'highlight', 'arrow', 'text', 'eraser')),
    stroke_data  JSONB       NOT NULL,   -- 좌표 배열, 0.0~1.0 정규화 (UC-04 기본흐름 2)
    color        VARCHAR(10),
    is_deleted   BOOLEAN     NOT NULL DEFAULT false,  -- 실행취소/전체삭제 (FR-03, UC-05)
    created_at   TIMESTAMP   NOT NULL DEFAULT now()
);

CREATE INDEX idx_annotation_score ON annotation(score_id);
CREATE INDEX idx_annotation_member ON annotation(member_id);

-- ============================================================
-- 6. AudioFile (음원 파일)
-- UC-06, UC-08, UC-10, UC-12, NR-07
-- ============================================================
CREATE TABLE audio_file (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id      UUID        NOT NULL REFERENCES room(id) ON DELETE CASCADE,
    uploaded_by  UUID        NOT NULL REFERENCES member(id),
    file_type    VARCHAR(10) NOT NULL
                 CHECK (file_type IN ('mp3', 'wav', 'flac', 'm4a')),  -- NR-07
    file_url     TEXT        NOT NULL,
    purpose      VARCHAR(20) NOT NULL
                 CHECK (purpose IN ('bpm', 'sync_original', 'sync_recorded', 'pitch', 'separation')),
    duration_sec INTEGER,
    uploaded_at  TIMESTAMP   NOT NULL DEFAULT now()
);

-- ============================================================
-- 7. AnalysisJob (분석 작업 — Celery 비동기)
-- UC-06~13, FR-11, FR-12, UC-14
-- ============================================================
CREATE TABLE analysis_job (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    audio_file_id   UUID        NOT NULL REFERENCES audio_file(id),
    room_id         UUID        NOT NULL REFERENCES room(id),
    job_type        VARCHAR(20) NOT NULL
                    CHECK (job_type IN ('bpm', 'sync', 'pitch', 'separation')),
    status          VARCHAR(20) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'processing', 'done', 'failed')),
    celery_task_id  VARCHAR(200),
    requested_at    TIMESTAMP   NOT NULL DEFAULT now(),
    completed_at    TIMESTAMP                           -- 완료 시각 (NR-01 측정용)
);

CREATE INDEX idx_job_room ON analysis_job(room_id);
CREATE INDEX idx_job_status ON analysis_job(status);

-- ============================================================
-- 8. BpmResult (BPM 분석 결과)
-- UC-07, FR-04, FR-05
-- ============================================================
CREATE TABLE bpm_result (
    id                  UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id              UUID  NOT NULL UNIQUE REFERENCES analysis_job(id) ON DELETE CASCADE,
    -- bpm_data: [{time: float, bpm: float}, ...] — librosa 구간별 결과 (FR-04)
    bpm_data            JSONB NOT NULL,
    base_bpm            FLOAT,
    -- deviation_sections: [{start: float, end: float, bpm: float}, ...] (FR-05)
    deviation_sections  JSONB
);

-- ============================================================
-- 9. SyncResult (싱크로율 분석 결과)
-- UC-09, FR-06, FR-07
-- ============================================================
CREATE TABLE sync_result (
    id                  UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id              UUID  NOT NULL UNIQUE REFERENCES analysis_job(id) ON DELETE CASCADE,
    overall_sync_pct    FLOAT NOT NULL,  -- 전체 싱크로율 % (FR-06)
    -- deviation_timeline: [{start: float, end: float, delta: float}, ...] (FR-07)
    deviation_timeline  JSONB NOT NULL
);

-- ============================================================
-- 10. PitchResult (피치 분석 결과)
-- UC-11, FR-08
-- ============================================================
CREATE TABLE pitch_result (
    id              UUID  PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id          UUID  NOT NULL UNIQUE REFERENCES analysis_job(id) ON DELETE CASCADE,
    -- pitch_timeline: [{start: float, end: float, semitone_diff: float}, ...] (FR-08)
    pitch_timeline  JSONB NOT NULL
);

-- ============================================================
-- 11. SeparatedTrack (분리된 트랙)
-- UC-12, UC-13, FR-09, FR-10
-- ============================================================
CREATE TABLE separated_track (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id      UUID        NOT NULL REFERENCES analysis_job(id) ON DELETE CASCADE,
    track_type  VARCHAR(20) NOT NULL
                CHECK (track_type IN ('vocals', 'drums', 'bass', 'guitar')),  -- Demucs 4트랙
    file_url    TEXT        NOT NULL,   -- S3/MinIO 분리 트랙 URL (UC-12 6단계)
    created_at  TIMESTAMP   NOT NULL DEFAULT now(),
    UNIQUE (job_id, track_type)
);

-- ============================================================
-- 요구사항 커버리지 요약
-- FR-01 room_code UNIQUE + room_participant
-- FR-02 annotation.tool_type CHECK
-- FR-03 annotation.is_deleted
-- FR-04 bpm_result.bpm_data JSONB
-- FR-05 bpm_result.deviation_sections JSONB
-- FR-06 sync_result.overall_sync_pct
-- FR-07 sync_result.deviation_timeline JSONB
-- FR-08 pitch_result.pitch_timeline JSONB
-- FR-09 separated_track.track_type CHECK (4종)
-- FR-10 separated_track.file_url
-- FR-11 analysis_job.status (pending→processing→done/failed)
-- FR-12 analysis_job.celery_task_id (WebSocket push 연동)
-- NR-05 room.room_code UNIQUE (코드 없이 접근 불가)
-- NR-07 audio_file.file_type CHECK (mp3/wav/flac/m4a)
-- ============================================================
