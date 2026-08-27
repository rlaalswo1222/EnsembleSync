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

# 키와 코드를 판정할 때 쓰는 스템과 섞는 비율.
#
# 드럼은 음정이 없는데도 타격음이 크로마 전 음에 퍼져서 판정을 흐린다.
# 보통은 하모닉 성분 분리(HPSS)를 돌려 걷어내는데 연산이 무겁다. 우리는
# demucs 가 이미 갈라 놓았으니 그냥 빼면 된다.
#
# 보컬도 뺀다. 선율은 화성 밖 음을 자주 지나가서 코드 판정을 흔든다.
# other 가 기타·건반 같은 화성, bass 가 근음을 맡는다.
# 6트랙 모델에서는 기타와 피아노가 따로 나온다. 화성을 직접 내는 악기라
# 그대로 쓴다. 스템이 없으면 그냥 건너뛰므로 4트랙 결과에도 그대로 돈다.
HARMONIC_STEMS = {
    "other": 1.0,
    "guitar": 1.0,
    "piano": 1.0,
    "bass": 0.8,
}

# 크로마를 뽑을 음역. C3 아래는 버린다.
#
# 베이스의 저음역은 CQT 해상도가 낮아 인접 반음으로 번진다. 실제로 이 곡의
# 한 구간에서 베이스만 뽑으면 G:1.00 옆에 G#:0.82 가 나란히 섰고, 그 탓에
# 3음을 정하지 못해 B단조 곡에 Gm 이 나왔다. 저역을 잘라내니 같은 구간이
# 반복 진행으로 또렷해졌다.
#
# 근음 정보를 잃는 게 아니다. 베이스가 내는 음의 배음은 C3 위에도 있다.
CHROMA_FMIN_NOTE = "C3"
CHROMA_OCTAVES = 4

# 조성 안 3화음에 얹는 점수.
#
# 조성 밖 코드를 막자는 게 아니다. 차용 화음이나 부속화음은 실제로 흔하고,
# 그것까지 걸러내면 맞는 답을 못 낸다. 근거가 팽팽할 때만 조성 안쪽으로
# 기울이라는 뜻이다.
#
# 크기를 실측해서 정했다. 1등과 2등 코드의 점수 차는 중앙값이 0.018 이라,
# 처음에 쓰려던 0.04 는 프레임의 32%를 뒤집었다. 그건 가중치가 아니라
# 판정을 대신하는 것이다. 0.005 면 5% 안쪽만 뒤집는다.
DIATONIC_BONUS = 0.005


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


def _diatonic_bonus(key: dict) -> np.ndarray:
    """조성 안 3화음에 [DIATONIC_BONUS] 를 얹은 24칸 배열.

    배열 순서는 [_chord_templates] 와 같다 (근음 순, 각 근음마다 장·단).
    """
    bonus = np.zeros(24)
    tonic_name, mode = key.get("tonic"), key.get("mode")
    if tonic_name not in PITCH_NAMES or mode not in ("major", "minor"):
        return bonus

    tonic = PITCH_NAMES.index(tonic_name)
    if mode == "major":
        # I ii iii IV V vi
        degrees = [(0, 0), (2, 1), (4, 1), (5, 0), (7, 0), (9, 1)]
    else:
        # i III iv v VI VII 에 화성단음계의 V(장3화음) 를 더한다.
        # 단조에서 딸림화음을 장3화음으로 쓰는 건 예외가 아니라 관용이다.
        degrees = [(0, 1), (3, 0), (5, 1), (7, 1), (8, 0), (10, 0), (7, 0)]

    for step, quality in degrees:
        bonus[((tonic + step) % 12) * 2 + quality] = DIATONIC_BONUS
    return bonus


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


# 새 코드가 이만큼 오래 이겨야 갈아탄다. (초)
#
# 바꾸는 값을 숫자 하나로 못 박지 않는다. 크로마 점수의 1등·2등 차이는
# 곡마다 다르다. 깨끗한 녹음은 차이가 크고, 드럼이 새어든 분리 트랙은
# 작다. 같은 값을 쓰면 어떤 곡은 잔떨림이 남고 어떤 곡은 코드가 뭉개진다.
#
# 그래서 곡마다 실제로 관측한 차이에 맞춰 정한다. 이 상수는 "얼마나 오래
# 버텨야 인정하나" 라는 음악적인 뜻만 가진다.
#
# 값은 실측으로 골랐다. 정답을 아는 소리를 만들어 코드 길이를 4박·2박·1박
# 으로 바꿔가며 쟀다(server/tools/chord_eval.py).
#
#            최빈값(예전)   0.5초   0.8초   1.5초   3.5초
#   4박 코드     93.3%      96.2%   98.2%   98.2%   98.2%
#   2박 코드     90.8%      94.1%   97.4%   97.5%   90.0%
#   1박 코드     67.2%      73.1%   73.6%   68.9%   50.9%
#
# 느린 진행은 0.8 이후로 평지지만 빠른 진행은 거기서 정점을 찍고 내려온다.
# 더 올려서 얻을 것이 없고, 코드가 자주 바뀌는 곡을 뭉갤 위험만 커진다.
COMMIT_SECONDS = 0.8


def _change_penalty(scores: np.ndarray, frames_per_second: float) -> float:
    """이 곡에서 코드를 바꾸는 데 치를 값을 정한다.

    1등과 2등의 점수 차를 프레임마다 재서 중앙값을 쓴다. 그것이 "한 프레임
    동안 벌 수 있는 이득" 이므로, 여기에 버텨야 할 프레임 수를 곱하면
    "그만큼 오래 이겨야 갈아탄다" 가 된다.
    """
    if scores.shape[1] == 0:
        return 0.0
    top2 = np.partition(scores, -2, axis=0)[-2:]
    margin = float(np.median(top2[1] - top2[0]))
    if not np.isfinite(margin) or margin <= 0:
        margin = 0.01
    return margin * COMMIT_SECONDS * frames_per_second


def _viterbi(scores: np.ndarray, penalty: float) -> np.ndarray:
    """프레임별 점수에서 가장 그럴듯한 코드 경로를 고른다.

    바꾸는 값이 어느 코드로 가든 같으므로, 매 프레임 "지금 상태를 유지" 와
    "가장 좋았던 상태에서 갈아타기" 둘만 견주면 된다. 24x24 를 다 볼 필요가
    없어서 프레임 수에 비례하는 시간만 든다.
    """
    n_states, n_frames = scores.shape
    if n_frames == 0:
        return np.zeros(0, dtype=np.int32)

    dp = np.empty((n_states, n_frames))
    back = np.empty((n_states, n_frames), dtype=np.int32)
    states = np.arange(n_states)

    dp[:, 0] = scores[:, 0]
    back[:, 0] = states

    for t in range(1, n_frames):
        prev = dp[:, t - 1]
        best_prev = int(prev.argmax())
        switch = prev[best_prev] - penalty
        take_switch = switch > prev
        dp[:, t] = np.where(take_switch, switch, prev) + scores[:, t]
        back[:, t] = np.where(take_switch, best_prev, states)

    path = np.empty(n_frames, dtype=np.int32)
    path[-1] = int(dp[:, -1].argmax())
    for t in range(n_frames - 1, 0, -1):
        path[t - 1] = back[path[t], t]
    return path


def detect_chords(
    chroma: np.ndarray, sr: int, hop_length: int, key: dict = None
) -> list:
    """프레임별로 가장 가까운 3화음을 고른 뒤 같은 코드끼리 구간으로 합친다."""
    templates, labels = _chord_templates()

    # 프레임별로 정규화해야 음량 차이가 아니라 음정 구성으로 비교된다.
    norms = np.linalg.norm(chroma, axis=0)
    silent = norms < 1e-3
    safe = np.where(silent, 1.0, norms)
    normalized = chroma / safe

    scores = templates @ normalized
    if key:
        # 조성 가중치는 프레임마다 같은 값을 더하는 것이라 접전만 뒤집는다.
        scores += _diatonic_bonus(key)[:, np.newaxis]
    # 프레임 단위 판정은 심하게 튄다. 눌러주는 방식이 중요하다.
    #
    # 예전에는 1초 창의 최빈값을 썼다. 한복판은 잘 맞았지만 코드가 바뀌는
    # 자리에서 창이 두 코드를 함께 물고 있어 경계가 최대 0.5초까지 밀렸다.
    # 실측으로 한복판 오류는 0%, 경계 언저리 오류는 23% 였다 — 틀리는
    # 것이 전부 경계였다는 뜻이다.
    #
    # 그래서 최빈값 대신 경로를 고른다. 코드를 바꿀 때마다 값을 치르게
    # 하면, 잠깐 흔들리는 것은 무시하고 진짜로 바뀐 자리에서는 즉시 바꾼다.
    # 경계가 뭉개지지 않으면서 한복판도 안정된다.
    smoothed = _viterbi(scores, _change_penalty(scores, sr / hop_length))

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


def _harmonic_signal(stem_paths: dict, mix_path: str):
    """키·코드 판정에 쓸 신호를 만든다.

    [HARMONIC_STEMS] 의 스템을 섞어 쓴다. 그 스템이 하나도 없으면
    (분석만 따로 돌리는 경우 등) 원본 믹스로 물러선다.
    """
    mixed = None
    for name, weight in HARMONIC_STEMS.items():
        path = stem_paths.get(name)
        if not path or not os.path.exists(path):
            continue
        y, _ = librosa.load(path, sr=ANALYSIS_SR, mono=True)
        y = y * weight
        if mixed is None:
            mixed = y
        else:
            size = min(len(mixed), len(y))
            mixed = mixed[:size] + y[:size]

    if mixed is None:
        mixed, _ = librosa.load(mix_path, sr=ANALYSIS_SR, mono=True)
    return mixed


def analyze(mix_path: str, stem_paths: dict, out_path: str) -> dict:
    """분석 일체를 돌리고 JSON 으로 저장한다.

    [mix_path] 는 길이를 재고 하모닉 스템이 없을 때 물러설 원본,
    [stem_paths] 는 {트랙이름: wav 경로} 형태의 분리 결과다.
    """
    peaks = {}
    duration = 0.0
    for name, path in stem_paths.items():
        if not os.path.exists(path):
            continue
        peaks[name] = waveform_peaks(path)
        duration = max(duration, len(peaks[name]) / PEAKS_PER_SECOND)

    y = _harmonic_signal(stem_paths, mix_path)
    chroma = librosa.feature.chroma_cqt(
        y=y,
        sr=ANALYSIS_SR,
        hop_length=HOP_LENGTH,
        fmin=librosa.note_to_hz(CHROMA_FMIN_NOTE),
        n_octaves=CHROMA_OCTAVES,
    )
    key = detect_key(chroma)

    result = {
        "version": 2,
        "duration": round(duration or float(len(y)) / ANALYSIS_SR, 2),
        "peaks_per_second": PEAKS_PER_SECOND,
        "peak_scale": PEAK_SCALE,
        "peaks": peaks,
        "key": key,
        "chords": detect_chords(chroma, ANALYSIS_SR, HOP_LENGTH, key=key),
    }

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)

    return result
