"""음원 길이를 읽는다.

분리에 걸리는 시간은 곡 길이에 거의 정비례한다. 실측으로 오디오 1초당
약 1.5초였다. 그런데 지금까지 남은 시간을 "최근 작업들의 평균"으로만
알려주고 있었다. 1분짜리와 6분짜리에 같은 숫자를 내놓았다는 뜻이다.

길이를 알면 곱하기 한 번으로 훨씬 나은 값이 나온다.

ffprobe 를 쓰지 않는다. API 컨테이너에는 ffmpeg 이 없고, 이것 하나 때문에
수백 MB 를 더 넣을 이유가 없다. mutagen 은 헤더만 읽으므로 가볍고 빠르다.
"""
import logging

log = logging.getLogger(__name__)

try:
    from mutagen import File as _MutagenFile
except ImportError:  # pragma: no cover - 설치 전 환경
    _MutagenFile = None


def seconds(path: str) -> int | None:
    """파일의 재생 길이(초). 못 읽으면 None.

    실패해도 업로드를 막지 않는다. 길이는 남은 시간을 더 잘 맞히기 위한
    것이지 없으면 안 되는 값이 아니다. 없으면 예전처럼 평균으로 돈다.
    """
    if _MutagenFile is None:
        return None
    try:
        audio = _MutagenFile(path)
        if audio is None or not getattr(audio, "info", None):
            return None
        value = getattr(audio.info, "length", None)
        if not value or value <= 0:
            return None
        return int(round(value))
    except Exception as e:
        log.warning("음원 길이를 읽지 못했습니다 (%s): %s", path, e)
        return None
