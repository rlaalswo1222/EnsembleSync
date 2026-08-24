"""코드 인식 정확도를 재는 자.

돌리는 법 (서버에서, 워커 컨테이너 안에 librosa 가 있다):

    C=$(docker ps -qf name=worker-bpm)
    docker cp server/tools/chord_eval.py "$C:/tmp/chord_eval.py"
    docker exec "$C" python /tmp/chord_eval.py --hard
    docker exec "$C" python /tmp/chord_eval.py --hard --beats 1

    # 후보 구현과 견주기
    docker exec "$C" python /tmp/chord_eval.py --hard         --module /tmp/candidate.py --penalty 0.8


눈으로 "맞는 것 같다" 를 고치면 안 된다. 전에 조성 가중치를 0.04 로 잡았다가
프레임의 32%를 뒤집은 적이 있다. 숫자가 있어야 나아졌는지 나빠졌는지 안다.

정답을 아는 소리를 직접 만들어 쓴다. 진짜 곡은 정답표가 없고, 있어도 저작권이
걸린다. 만든 소리는 정답이 확실하고 몇 번이든 다시 돌릴 수 있다.

소리는 실제 악기에 가깝게 만든다.
  - 배음을 여러 개 쌓는다. 사인파 하나로는 CQT 가 너무 깨끗해서 실제보다
    쉬운 문제가 된다.
  - 베이스는 근음을 한두 옥타브 아래에서 낸다. 실제 밴드가 그렇게 친다.
  - 자리바꿈(전위)을 섞는다. 코드 구성음이 같아도 최저음이 다르면 사람은
    다른 코드로 듣는다.
  - 앞뒤에 살짝 여운을 준다. 코드가 칼같이 끊기지 않는다.
"""
import sys

import numpy as np

SR = 22050
PITCH = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

MAJOR = [0, 4, 7]
MINOR = [0, 3, 7]


def midi_hz(m):
    return 440.0 * (2.0 ** ((m - 69) / 12.0))


def tone(freq, dur, sr=SR, harmonics=6):
    """배음을 쌓은 소리 하나. 사인파 하나보다 실제 악기에 가깝다."""
    t = np.linspace(0, dur, int(sr * dur), endpoint=False)
    y = np.zeros_like(t)
    for h in range(1, harmonics + 1):
        # 배음은 위로 갈수록 작아진다. 실제 현·건반이 그렇다.
        y += (1.0 / h**1.4) * np.sin(2 * np.pi * freq * h * t)
    # 치고 잦아드는 모양.
    env = np.exp(-2.2 * t / max(dur, 1e-6))
    attack = np.minimum(1.0, t / 0.02)
    return y * env * attack


SEVENTHS = {"": [0, 4, 7, 11], "m": [0, 3, 7, 10]}


def render(progression, beats_per_chord=4, bpm=100, sr=SR, seed=0,
           hard=False):
    """코드 진행을 소리로 만든다. (오디오, 정답 구간 목록)"""
    rng = np.random.default_rng(seed)
    spb = 60.0 / bpm
    dur = beats_per_chord * spb

    audio = []
    truth = []
    at = 0.0
    for root, quality in progression:
        intervals = MAJOR if quality == "" else MINOR
        # 자리바꿈. 실제 연주는 늘 근음이 맨 아래에 있지 않다.
        inversion = int(rng.integers(0, 3))
        notes = [root + 60 + iv for iv in intervals]
        notes = notes[inversion:] + [n + 12 for n in notes[:inversion]]

        chunk = np.zeros(int(sr * dur))
        if hard:
            # 아르페지오. 기타도 건반도 화음을 한꺼번에 눌러 끝까지 붙들고
            # 있지 않는다. 뜯거나 나눠 치기 때문에 어느 순간에는 구성음 중
            # 한둘만 울린다.
            #
            # 실제 곡의 프레임 판정이 심하게 튀는 가장 큰 이유가 이것이다.
            # 이게 없으면 한복판이 너무 쉬워져서, 눌러주는 장치가 쓸모없어
            # 보이는 잘못된 결론이 나온다.
            per = dur / (beats_per_chord * 2)
            for k in range(beats_per_chord * 2):
                m = notes[k % len(notes)]
                s = tone(midi_hz(m), per * 1.6, sr)
                at_i = int(k * per * sr)
                room = len(chunk) - at_i
                chunk[at_i:at_i + len(s)] += s[:room] * 0.75
        else:
            for m in notes:
                s = tone(midi_hz(m), dur, sr)
                chunk[: len(s)] += s * 0.6

        if hard:
            # 7화음. 악보에는 F#m7 이라고 적혀 있어도 우리가 답해야 하는
            # 것은 F#m 이다. 7음이 들어가면 다른 3화음과 겹치기 시작한다 —
            # Cmaj7 의 구성음은 Em 을 통째로 품는다.
            extra = SEVENTHS[quality][3]
            s7 = tone(midi_hz(root + 60 + extra), dur, sr)
            chunk[: len(s7)] += s7 * 0.45

            # 선율. 화음 밖 음을 지나간다. 보컬을 빼도 other 스템에 리드가
            # 남아 있어서 실제로 이런 소리가 섞인다.
            steps = [0, 2, 4, 5, 7, 9, 11]
            for k in range(beats_per_chord):
                deg = int(rng.integers(0, len(steps)))
                mel = tone(
                    midi_hz(root + 72 + steps[deg]), spb * 0.9, sr, harmonics=4
                )
                at_i = int(k * spb * sr)
                chunk[at_i:at_i + len(mel)] += mel[: len(chunk) - at_i] * 0.5

            # 타악 잔재. 드럼을 분리해 빼도 완전히 없어지지 않는다. 타격음은
            # 크로마 열두 칸에 고르게 번져서 판정을 흐린다.
            for k in range(beats_per_chord * 2):
                at_i = int(k * spb * 0.5 * sr)
                n = int(sr * 0.05)
                burst = rng.normal(0, 1, n) * np.exp(
                    -np.linspace(0, 8, n)
                )
                chunk[at_i:at_i + n] += burst[: len(chunk) - at_i] * 0.35

        # 베이스는 언제나 근음을 낸다. 자리바꿈을 해도 밴드의 베이스는
        # 근음을 잡는 경우가 대부분이다.
        b = tone(midi_hz(root + 36), dur, sr, harmonics=4)
        chunk[: len(b)] += b * 0.9

        audio.append(chunk)
        truth.append((at, at + dur, f"{PITCH[root % 12]}{quality}"))
        at += dur

    y = np.concatenate(audio)

    if hard:
        # 잔향. 앞 코드가 다음 코드 위로 새어든다. 실제 녹음에서 코드 경계가
        # 흐려지는 가장 큰 이유다.
        ir = np.exp(-np.linspace(0, 6, int(sr * 0.6))) * rng.normal(
            0, 1, int(sr * 0.6)
        )
        wet = np.convolve(y, ir, mode="same")
        y = y + wet / (np.max(np.abs(wet)) + 1e-9) * 0.25 * np.max(np.abs(y))
        # 바닥 잡음.
        y = y + rng.normal(0, 1, len(y)) * 0.01 * np.max(np.abs(y))

    y = y / (np.max(np.abs(y)) + 1e-9) * 0.9
    return y.astype(np.float32), truth


def label_at(truth, t):
    for start, end, label in truth:
        if start <= t < end:
            return label
    return None


def diagnose(detected, truth, total_dur, edge=0.4, step=0.05):
    """어디서 틀리는지 나눠 센다.

    코드가 바뀌는 언저리에서 틀리는 것과 한복판에서 틀리는 것은 원인이
    전혀 다르다. 앞쪽이면 시간축을 다루는 방식이 문제고, 뒤쪽이면 소리를
    읽는 방식이 문제다.
    """
    edge_bad = edge_n = mid_bad = mid_n = 0
    confusions = {}
    for start, end, want in truth:
        for t in np.arange(start, end, step):
            if t >= total_dur:
                break
            got = label_at(detected, t)
            near_edge = (t - start) < edge or (end - t) < edge
            if near_edge:
                edge_n += 1
            else:
                mid_n += 1
            if got != want:
                if near_edge:
                    edge_bad += 1
                else:
                    mid_bad += 1
                k = f"{want}->{got}"
                confusions[k] = confusions.get(k, 0) + 1
    return {
        "edge": edge_bad / edge_n if edge_n else 0,
        "mid": mid_bad / mid_n if mid_n else 0,
        "confusions": confusions,
    }


def score(detected, truth, total_dur, step=0.05):
    """시간축에서 정답과 겹치는 비율.

    구간 개수가 아니라 시간으로 잰다. 4분 코드 하나를 통째로 틀리는 것과
    짧은 파편 하나를 틀리는 것은 무게가 다르다.
    """
    hits = root_hits = n = 0
    for t in np.arange(0.0, total_dur, step):
        want = label_at(truth, t)
        if want is None:
            continue
        got = label_at(detected, t)
        n += 1
        if got == want:
            hits += 1
        # 근음만 맞아도 따로 센다. 장단조를 헷갈리는 것과 근음을 놓치는
        # 것은 원인이 다르다.
        if got and got.rstrip("m") == want.rstrip("m"):
            root_hits += 1
    return (hits / n if n else 0.0), (root_hits / n if n else 0.0)


# ── 시험곡 ────────────────────────────────────────────────
# 실제로 흔한 진행들. 상대 장·단조가 섞인 것을 일부러 넣었다 — 구성음이
# 겹쳐서 템플릿 맞추기가 가장 잘 틀리는 자리다.
SUITES = {
    "C 장조 1-5-6-4": [(0, ""), (7, ""), (9, "m"), (5, "")],
    "A 단조 6-4-1-5": [(9, "m"), (5, ""), (0, ""), (7, "")],
    "카논 진행": [(0, ""), (7, ""), (9, "m"), (4, "m"), (5, ""), (0, ""), (5, ""), (7, "")],
    "F# 단조": [(6, "m"), (9, ""), (2, ""), (4, "")],
    "재즈 2-5-1": [(2, "m"), (7, ""), (0, ""), (0, "")],
    "반음 이동": [(0, ""), (1, ""), (2, "m"), (3, "")],
}


def load_module(path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("candidate", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    sys.path.insert(0, "/app")
    # 후보 구현을 따로 지정할 수 있다. 운영 중인 파일을 건드리지 않고
    # 견주기 위해서다.
    path = None
    for i, a in enumerate(sys.argv):
        if a == "--module" and i + 1 < len(sys.argv):
            path = sys.argv[i + 1]
    ta = load_module(path) if path else __import__("track_analysis")

    # 코드 바꾸는 값과 코드 길이를 밖에서 정한다.
    #
    # 길이를 바꿔가며 재는 것이 중요하다. 한 가지 길이에만 맞춘 값은 그
    # 시험지에만 잘 듣는다. 4박 코드와 2박 코드에서 함께 좋아야 쓸 만하다.
    penalty = None
    beats = 4
    for i, a in enumerate(sys.argv):
        if a == "--penalty" and i + 1 < len(sys.argv):
            penalty = float(sys.argv[i + 1])
        if a == "--beats" and i + 1 < len(sys.argv):
            beats = int(sys.argv[i + 1])
    if penalty is not None:
        # 절대값을 쓰던 판과 "얼마나 버텨야 하나" 로 바꾼 판을 둘 다 잰다.
        if hasattr(ta, "COMMIT_SECONDS"):
            ta.COMMIT_SECONDS = penalty
        elif hasattr(ta, "CHANGE_PENALTY"):
            ta.CHANGE_PENALTY = penalty

    quiet = "--quiet" in sys.argv
    if not quiet:
        print(f"대상: {path or '/app/track_analysis.py (운영)'}"
              f"  penalty={penalty}  beats={beats}")

    hard = "--hard" in sys.argv
    if not quiet:
        print(f"{'진행':<16} {'정확도':>7} {'근음':>7}   "
              f"({'어려움' if hard else '쉬움'})")
        print("-" * 42)
    total_acc = []
    total_root = []
    edges, mids, all_conf = [], [], {}
    seg_ratio = []
    for i, (name, prog) in enumerate(SUITES.items()):
        # 씨앗을 번호로 고정한다. hash() 는 파이썬이 실행마다 뒤섞으므로
        # 같은 코드를 두 번 재도 다른 값이 나온다. 그러면 나아진 것인지
        # 씨앗이 달라진 것인지 가릴 수 없다.
        y, truth = render(
            prog * 2, beats_per_chord=beats, seed=1000 + i, hard=hard
        )
        dur = len(y) / SR

        chroma = ta.librosa.feature.chroma_cqt(
            y=y,
            sr=SR,
            hop_length=ta.HOP_LENGTH,
            fmin=ta.librosa.note_to_hz(ta.CHROMA_FMIN_NOTE),
            n_octaves=ta.CHROMA_OCTAVES,
        )
        key = ta.detect_key(chroma)
        chords = ta.detect_chords(chroma, SR, ta.HOP_LENGTH, key=key)
        detected = [(c["time"], c["end"], c["label"]) for c in chords]

        acc, root = score(detected, truth, dur)
        total_acc.append(acc)
        total_root.append(root)
        if not quiet:
            print(f"{name:<16} {acc*100:6.1f}% {root*100:6.1f}%")

        seg_ratio.append(len(detected) / max(1, len(truth)))
        d = diagnose(detected, truth, dur)
        edges.append(d["edge"])
        mids.append(d["mid"])
        for k, v in d["confusions"].items():
            all_conf[k] = all_conf.get(k, 0) + v

    if quiet:
        print(f"penalty={penalty} beats={beats} "
              f"acc={np.mean(total_acc)*100:5.2f} "
              f"edge={np.mean(edges)*100:5.2f} mid={np.mean(mids)*100:5.2f} "
              f"seg={np.mean(seg_ratio):4.2f}x")
        return

    print("-" * 42)
    print(f"{'평균':<16} {np.mean(total_acc)*100:6.1f}% "
          f"{np.mean(total_root)*100:6.1f}%")

    print()
    print(f"코드 바뀌는 언저리(±0.4초) 오류율 : {np.mean(edges)*100:5.1f}%")
    print(f"코드 한복판 오류율               : {np.mean(mids)*100:5.1f}%")
    print(f"구간 조각남 (1.0 이 정답)         : {np.mean(seg_ratio):5.2f}배")
    if all_conf:
        print()
        print("가장 흔한 혼동 (정답->오답, 프레임 수)")
        for k, v in sorted(all_conf.items(), key=lambda x: -x[1])[:8]:
            print(f"  {k:<14} {v}")


if __name__ == "__main__":
    main()
