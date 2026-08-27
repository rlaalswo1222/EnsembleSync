"""이 컴퓨터에서 음원 분리가 얼마나 걸리는지 잰다.

지금 서버(오라클 2코어)에서 3분 20초 곡이 302초 걸린다. 집 컴퓨터를 분석
일꾼으로 붙일 값어치가 있는지는 같은 길이를 같은 방식으로 재봐야 안다.

시험용 소리는 여기서 만든다. 진짜 곡을 쓰면 저작권이 걸리고, 무엇보다
demucs 가 걸리는 시간은 곡의 내용이 아니라 길이로 정해지므로 만든 소리로도
같은 값이 나온다.

돌리는 법 (윈도우 · 파이썬 3.10 이상):

    python -m venv .bench
    .bench\\Scripts\\activate
    pip install demucs soundfile
    python server/tools/bench_local.py

처음 한 번은 demucs 모델(약 80MB)을 내려받느라 시간이 더 걸린다. 그건
재는 시간에 넣지 않는다.
"""
import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time

# 오라클 서버에서 실측한 값. 견줄 기준이다.
SERVER_SECONDS = 302.2
SERVER_NOTE = "오라클 2 OCPU (Neoverse-N1), htdemucs, 동시 실행 1개"

# 시험용 소리의 길이. 서버에서 잰 곡과 같게 맞춘다.
DURATION = 199.6
SR = 44100
MODEL = "htdemucs"


def make_audio(path: str) -> None:
    """분리할 소리를 만든다.

    화음 몇 개와 잡음을 섞는다. 정확한 소리는 중요하지 않다 — demucs 는
    무음이든 관현악이든 같은 길이면 거의 같은 시간이 걸린다. 다만 완전한
    무음은 내부에서 건너뛸 수 있으므로 소리가 차 있게 만든다.
    """
    import numpy as np
    import soundfile as sf

    n = int(SR * DURATION)
    t = np.arange(n, dtype=np.float32) / SR
    y = np.zeros(n, dtype=np.float32)
    for f in (110.0, 164.81, 220.0, 329.63):
        y += np.sin(2 * np.pi * f * t).astype(np.float32) * 0.18
    rng = np.random.default_rng(0)
    y += rng.normal(0, 0.04, n).astype(np.float32)
    y = np.clip(y, -1.0, 1.0)
    sf.write(path, np.stack([y, y], axis=1), SR)


def describe_machine() -> str:
    cpu = platform.processor() or platform.machine()
    try:
        import psutil

        phys = psutil.cpu_count(logical=False)
        log = psutil.cpu_count(logical=True)
        ram = psutil.virtual_memory().total / (1024 ** 3)
        return f"{cpu} · 코어 {phys} / 스레드 {log} · 램 {ram:.0f}GB"
    except Exception:
        return f"{cpu} · 스레드 {os.cpu_count()}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=0,
                    help="demucs -j 값. 0 이면 주지 않는다")
    ap.add_argument("--keep", action="store_true", help="결과 파일을 남긴다")
    args = ap.parse_args()

    print(f"기계   {describe_machine()}")
    print(f"기준   {SERVER_SECONDS:.1f}초 — {SERVER_NOTE}")
    print()

    work = tempfile.mkdtemp(prefix="bandly_bench_")
    src = os.path.join(work, "test.wav")
    out = os.path.join(work, "out")

    try:
        print(f"시험용 소리 {DURATION:.0f}초를 만드는 중...")
        make_audio(src)

        cmd = [sys.executable, "-m", "demucs", "--name", MODEL, "--out", out]
        if args.jobs:
            cmd += ["-j", str(args.jobs)]
        cmd.append(src)

        # 모델을 처음 받는 시간은 재지 않는다. 한 번만 드는 값이라
        # 평소 걸리는 시간과 상관이 없다.
        print("모델을 준비하는 중... (처음이면 80MB 내려받는다)")
        warm = subprocess.run(
            cmd[:-1] + ["--help"], capture_output=True, text=True
        )
        if warm.returncode != 0:
            print("demucs 를 실행할 수 없다. pip install demucs 를 먼저 해야 한다.")
            return 1

        print("분리를 시작한다...")
        t0 = time.perf_counter()
        proc = subprocess.run(cmd, capture_output=True, text=True)
        wall = time.perf_counter() - t0

        if proc.returncode != 0:
            print("\n실패했다. demucs 가 남긴 말:")
            print((proc.stderr or proc.stdout or "").strip()[-1500:])
            return 1

        ratio = SERVER_SECONDS / wall
        print()
        print(f"걸린 시간        {wall:6.1f}초")
        print(f"오디오 1초당     {wall / DURATION:6.2f}초")
        print(f"지금 서버 대비   {ratio:6.2f}배")
        print()
        # 실제로 앱에서 겪게 될 시간으로 바꿔 말해준다.
        for song in (180, 240, 300):
            here = wall / DURATION * song
            there = SERVER_SECONDS / DURATION * song
            print(f"  {song // 60}분 {song % 60:02d}초 곡 "
                  f"→ 여기 {here / 60:.1f}분 · 서버 {there / 60:.1f}분")
        return 0
    finally:
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
        else:
            print(f"\n결과는 {work} 에 남겼다.")


if __name__ == "__main__":
    raise SystemExit(main())
