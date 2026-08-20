"""분리 트랙에 얹는 부가 분석 — 파형 피크, 키(조), 코드 진행.

분리(demucs)가 끝난 시점에 함께 돌린다. 그 시점에는 ffmpeg 이 만든 WAV 와
분리된 스템 4개가 모두 디스크에 있어서, 디코딩을 다시 할 필요가 없다.
4분짜리 곡 기준 총 3초 남짓 든다 (demucs 자체가 수 분이라 사실상 공짜).

결과는 /uploads/separated/{job_id}/analysis.json 에 쓴다. /uploads 는 이미
정적 서빙 중이라 클라이언트가 별도 API 없이 바로 받아간다.
"""

import json
import os

import librosa
import numpy as np
import soundfile as sf

# 파형 피크 해상도. 초당 20개면 화면에 그리기 충분하고 4분 곡이 트랙당 4800개다.
PEAKS_PER_SECOND = 20

# 피크는 0~255 정수로 저장한다. float 로 두면 JSON 크기가 3배가 된다.
PEAK_SCALE = 255

# 키/코드 분석용 샘플레이트. 원본을 그대로 쓸 이유가 없다.
ANALYSIS_SR = 22050
HOP_LENGTH = 512

PITCH_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Krumhansl-Schmuckler 조성 프로파일. 각 조에서 12음이 얼마나 자주 쓰이는지의 통계.
_KS_MAJOR = np.array(
    [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
)
_KS_MINOR = np.array(
    [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
)

# 코드 판별용 3화음 템플릿 (근음 기준 반음 간격).
_MAJOR_TRIAD = [0, 4, 7]
_MINOR_TRIAD = [0, 3, 7]

# 이보다 짧은 코드 구간은 잡음으로 보고 앞 구간에 흡수시킨다.
MIN_CHORD_DURATION = 0.4


def waveform_peaks(path: str, per_second: int = PEAKS_PER_SECOND) -> list:
    """오디오 파일을 구간별 최대 진폭 배열로 줄인다.

    파형 그리기가 목적이라 리샘플링도 정규화도 필요 없다. 그냥 절댓값의
    구간 최대치를 뽑는다. 디코딩 없이 WAV 를 그대로 읽어서 매우 빠르다.
    """
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1)

    bucket = max(1, sr // per_second)
    count = int(np.ceil(len(mono) / bucket))
    if count == 0:
        return []

    # 마지막 구간 길이를 맞추기 위해 0 으로 채운 뒤 reshape 한다.
    padded = np.zeros(count * bucket, dtype=np.float32)
    padded[: len(mono)] = mono
    peaks = np.abs(padded.reshape(count, bucket)).max(axis=1)

    # 트랙마다 음량이 달라도 파형 모양이 보이도록 트랙 자체 최대치로 정규화한다.
    top = float(peaks.max())
    if top > 0:
        peaks = peaks / top

    return np.round(peaks * PEAK_SCALE).astype(np.uint8).tolist()


def detect_key(chroma: np.ndarray) -> dict:
    """평균 크로마를 24개 조성 프로파일과 상관시켜 조를 고른다."""
    profile = chroma.mean(axis=1)
    if not np.any(profile):
        return {"tonic": None, "mode": None, "label": "unknown", "confidence": 0.0}

    profile = profile - profile.mean()
    scores = []
    for tonic in range(12):
        for mode, template in (("major", _KS_MAJOR), ("minor", _KS_MINOR)):
            shifted = np.roll(template, tonic)
            shifted = shifted - shifted.mean()
            denom = np.linalg.norm(profile) * np.linalg.norm(shifted)
            corr = float(np.dot(profile, shifted) / denom) if denom else 0.0
            scores.append((corr, tonic, mode))

    scores.sort(reverse=True)
    best_corr, tonic, mode = scores[0]
    runner_up = scores[1][0]

    # 1등과 2등의 격차를 신뢰도로 쓴다. 조성이 모호한 곡이면 격차가 작다.
    confidence = max(0.0, min(1.0, best_corr - runner_up))

    return {
        "tonic": PITCH_NAMES[tonic],
        "mode": mode,
        "label": f"{PITCH_NAMES[tonic]} {'Major' if mode == 'major' else 'Minor'}",
        "confidence": round(confidence, 3),
    }


def _chord_templates() -> tuple:
    """24개 3화음 템플릿과 이름표를 만든다."""
    templates, labels = [], []
    for tonic in range(12):
        for intervals, suffix in ((_MAJOR_TRIAD, ""), (_MINOR_TRIAD, "m")):
            vec = np.zeros(12)
            for iv in intervals:
                vec[(tonic + iv) % 12] = 1.0
            templates.append(vec / np.linalg.norm(vec))
            labels.append(f"{PITCH_NAMES[tonic]}{suffix}")
    return np.array(templates), labels


def detect_chords(chroma: np.ndarray, sr: int, hop_length: int) -> list:
    """프레임별로 가장 가까운 3화음을 고른 뒤 같은 코드끼리 구간으로 합친다."""
    templates, labels = _chord_templates()

    # 프레임별로 정규화해야 음량 차이가 아니라 음정 구성으로 비교된다.
    norms = np.linalg.norm(chroma, axis=0)
    silent = norms < 1e-3
    safe = np.where(silent, 1.0, norms)
    normalized = chroma / safe

    best = (templates @ normalized).argmax(axis=0)

    # 프레임 단위 판정은 심하게 튄다. 약 1초 창의 최빈값으로 눌러준다.
    window = max(1, int(round(sr / hop_length)))
    smoothed = np.empty_like(best)
    for i in range(len(best)):
        lo = max(0, i - window // 2)
        hi = min(len(best), i + window // 2 + 1)
        counts = np.bincount(best[lo:hi], minlength=len(labels))
        smoothed[i] = counts.argmax()

    times = librosa.frames_to_time(
        np.arange(len(smoothed) + 1), sr=sr, hop_length=hop_length
    )

    segments = []
    start_idx = 0
    for i in range(1, len(smoothed) + 1):
        ended = i == len(smoothed) or smoothed[i] != smoothed[start_idx]
        if not ended:
            continue
        label = "N" if silent[start_idx] else labels[smoothed[start_idx]]
        segments.append(
            {
                "time": round(float(times[start_idx]), 2),
                "end": round(float(times[i]), 2),
                "label": label,
            }
        )
        start_idx = i

    return _merge_short(segments)


def _merge_short(segments: list) -> list:
    """짧은 파편을 앞 구간에 흡수시킨다. 화면에서 코드가 깜빡이는 걸 막는다."""
    merged = []
    for seg in segments:
        duration = seg["end"] - seg["time"]
        if merged and duration < MIN_CHORD_DURATION:
            merged[-1]["end"] = seg["end"]
            continue
        if merged and merged[-1]["label"] == seg["label"]:
            merged[-1]["end"] = seg["end"]
            continue
        merged.append(dict(seg))
    return merged


def analyze(mix_path: str, stem_paths: dict, out_path: str) -> dict:
    """분석 일체를 돌리고 JSON 으로 저장한다.

    [mix_path] 는 키/코드 분석에 쓰는 원본(또는 ffmpeg 변환본),
    [stem_paths] 는 {트랙이름: wav 경로} 형태의 분리 결과다.
    """
    peaks = {}
    duration = 0.0
    for name, path in stem_paths.items():
        if not os.path.exists(path):
            continue
        peaks[name] = waveform_peaks(path)
        duration = max(duration, len(peaks[name]) / PEAKS_PER_SECOND)

    y, sr = librosa.load(mix_path, sr=ANALYSIS_SR, mono=True)
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=HOP_LENGTH)

    result = {
        "version": 1,
        "duration": round(duration or float(len(y)) / sr, 2),
        "peaks_per_second": PEAKS_PER_SECOND,
        "peak_scale": PEAK_SCALE,
        "peaks": peaks,
        "key": detect_key(chroma),
        "chords": detect_chords(chroma, sr, HOP_LENGTH),
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)

    return result
