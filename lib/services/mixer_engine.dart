import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// 분리된 트랙 여러 개를 한 덩어리처럼 재생하는 엔진.
///
/// SoLoud 는 모든 소리를 하나의 믹서에서 같은 클럭으로 섞는다. 트랙마다
/// 재생기를 따로 두는 방식과 달리 시간이 지나도 어긋나지 않는다.
/// (실측: 4트랙 동시 재생 중 트랙 간 위치 차이 0.0ms)
///
/// 재생 위치는 [position] 으로 따로 뺐다. 초당 수십 번 바뀌는 값이라
/// [ChangeNotifier] 에 섞으면 화면 전체가 그 빈도로 다시 그려진다.
class MixerEngine extends ChangeNotifier {
  final SoLoud _soloud = SoLoud.instance;

  final Map<String, AudioSource> _sources = <String, AudioSource>{};
  final Map<String, SoundHandle> _handles = <String, SoundHandle>{};
  final Map<String, double> _volumes = <String, double>{};
  final Set<String> _muted = <String>{};

  /// 재생 위치. 30fps 로 갱신되므로 이 값을 듣는 위젯만 다시 그려진다.
  final ValueNotifier<Duration> position =
      ValueNotifier<Duration>(Duration.zero);

  Timer? _ticker;

  /// 이미 정리된 엔진인지. load() 가 비동기라, 트랙을 받는 도중에 화면이
  /// 사라지면 await 이 끝난 뒤에도 코드가 이어서 돈다. 그때 알림을 보내면
  /// "used after being disposed" 로 터진다.
  bool _disposed = false;

  List<String> _order = const <String>[];
  String? _soloed;
  Duration _length = Duration.zero;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _isReady = false;
  bool _looping = false;
  bool _pitchAvailable = false;
  int _semitones = 0;
  String? _error;
  String _loadingLabel = '';

  /// 키 조절 한계. ±7 을 넘어가면 실시간 피치 시프트 특유의 금속음이 든다.
  static const int maxSemitones = 7;

  /// 오디오 엔진 초기화를 기다리는 한계.
  ///
  /// SoLoud 의 init() 은 앞선 초기화 뒤에 줄을 서는 구조라, 한 번 멈추면
  /// 그 뒤 호출이 전부 매달린 채 영영 돌아오지 않는다. 화면에 "오디오 엔진
  /// 준비 중" 만 떠 있게 되므로 시간을 끊고 한 번 되살려 본다.
  static const Duration _initTimeout = Duration(seconds: 12);

  List<String> get order => _order;
  Duration get length => _length;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  bool get isReady => _isReady;
  bool get looping => _looping;
  bool get pitchAvailable => _pitchAvailable;
  int get semitones => _semitones;
  String? get error => _error;
  String get loadingLabel => _loadingLabel;
  String? get soloed => _soloed;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  double volumeOf(String id) => _volumes[id] ?? 1.0;
  bool isMuted(String id) => _muted.contains(id);
  bool isSoloed(String id) => _soloed == id;

  /// 솔로가 걸려 있으면 그 트랙만, 아니면 음소거되지 않은 트랙만 들린다.
  bool isAudible(String id) =>
      _soloed != null ? _soloed == id : !_muted.contains(id);

  /// [urls] 는 {트랙 id: 오디오 주소}. 순서가 곧 화면에 쌓이는 순서다.
  Future<void> load(Map<String, String> urls) async {
    if (_isLoading || _disposed) return;
    _isLoading = true;
    _isReady = false;
    _error = null;
    _order = urls.keys.toList();
    _notify();

    try {
      if (!_soloud.isInitialized) {
        _loadingLabel = '오디오 엔진 준비 중';
        _notify();
        await _initEngine();
      }
      if (_disposed) return;

      // 웹에서는 트랙별 필터가 막혀 있어 전역 필터만 쓸 수 있다. 키 조절은
      // 어차피 곡 전체에 걸리는 것이라 전역으로 충분하다.
      //
      // 쓸 수 있는지만 확인하고 곧바로 끈다.
      //
      // 예전에는 켜 둔 채로 두었다. 0반음이면 아무 일도 안 할 것이라
      // 여겼는데 그렇지 않았다. 피치 시프트는 소리를 잘게 잘라 늘렸다
      // 줄였다 겹쳐 붙이는 방식이라, 0에서도 신호가 그 과정을 한 번
      // 통과하면서 음량이 깎인다. 원본보다 눈에 띄게 작게 들렸다.
      try {
        final filter = _soloud.filters.pitchShiftFilter;
        if (!filter.isActive) filter.activate();
        _pitchAvailable = filter.isActive;
        if (_pitchAvailable) filter.deactivate();
      } catch (_) {
        _pitchAvailable = false;
      }

      // 앞 곡에서 올려둔 키가 필터에 남아 있을 수 있다. 이 객체는 곡마다
      // 새로 만들어져 _semitones 가 0 으로 시작하므로, 화면은 '원키'라고
      // 하는데 소리는 올라간 채가 된다. 여기서 한 번 맞춘다.
      _applyPitch();

      for (final MapEntry<String, String> e in urls.entries) {
        _loadingLabel = '${e.key} 불러오는 중';
        _notify();
        final AudioSource source = await _soloud.loadUrl(e.value);
        if (_disposed) {
          // 기다리는 사이에 화면이 사라졌다. 방금 받은 것도 되돌려 놓는다.
          unawaited(_soloud.disposeSource(source));
          return;
        }
        _sources[e.key] = source;
        _volumes[e.key] = 1.0;
      }

      if (_sources.isNotEmpty) {
        _length = _soloud.getLength(_sources.values.first);
      }
      _isReady = true;
      _loadingLabel = '';
    } catch (e) {
      _error = '$e';
    } finally {
      _isLoading = false;
      if (!_disposed) _notify();
    }
  }

  /// 엔진을 띄운다. 멈추면 한 번 내렸다가 다시 시도한다.
  ///
  /// 앱을 핫 리스타트하면 네이티브 쪽 엔진이 살아 있는 채로 Dart 만 새로
  /// 시작해서 init() 이 돌아오지 않는 일이 있다. 그때는 deinit() 으로
  /// 정리하고 다시 띄우면 살아난다.
  Future<void> _initEngine() async {
    try {
      await _soloud.init().timeout(_initTimeout);
      return;
    } on TimeoutException {
      _log('오디오 엔진 초기화가 ${_initTimeout.inSeconds}초를 넘겼다. 다시 시도한다.');
    }

    if (_disposed) return;

    try {
      _soloud.deinit();
    } catch (e) {
      _log('deinit 실패(무시): $e');
    }
    await _soloud.init().timeout(
          _initTimeout,
          onTimeout: () => throw Exception(
            '오디오 엔진을 시작하지 못했습니다. 앱을 완전히 껐다가 다시 켜주세요.',
          ),
        );
  }

  void _log(String message) => debugPrint('[MixerEngine] $message');

  void togglePlay() => _isPlaying ? pause() : play();

  /// 전부 멈춘 상태로 띄운 뒤 한꺼번에 재생을 푼다. 하나씩 play() 하면
  /// 호출 간격만큼 그대로 어긋난 채 시작한다.
  void play() {
    if (!_isReady || _disposed) return;
    if (_handles.isEmpty) {
      for (final MapEntry<String, AudioSource> e in _sources.entries) {
        _handles[e.key] = _soloud.play(
          e.value,
          volume: _effectiveVolume(e.key),
          paused: true,
        );
      }
    }
    for (final SoundHandle h in _handles.values) {
      _soloud.setPause(h, false);
    }
    _isPlaying = true;
    _startTicker();
    _notify();
  }

  void pause() {
    if (_disposed) return;
    for (final SoundHandle h in _handles.values) {
      _soloud.setPause(h, true);
    }
    _isPlaying = false;
    _ticker?.cancel();
    _notify();
  }

  /// 곡 맨 끝으로는 보내지 않고 이만큼 앞에서 멈춘다.
  ///
  /// 마지막 샘플 위치로 seek 하면 SoLoud 가 범위를 벗어난 값으로 보고
  /// InvalidParameter 예외를 던진다. 재생 바를 끝까지 끌면 바로 걸린다.
  static const Duration _endGuard = Duration(milliseconds: 120);

  void seek(Duration to) {
    if (_disposed) return;

    Duration clamped = to < Duration.zero ? Duration.zero : to;
    if (_length > Duration.zero) {
      Duration limit = _length - _endGuard;
      if (limit < Duration.zero) {
        limit = Duration.zero;
      }
      if (clamped > limit) {
        clamped = limit;
      }
    }

    if (_handles.isEmpty) {
      // 아직 재생 전이라면 눈금만 옮겨 두고, 재생 시작 때 맞춰 넣는다.
      position.value = clamped;
      return;
    }
    for (final SoundHandle h in _handles.values) {
      try {
        _soloud.seek(h, clamped);
      } catch (e) {
        // 곡이 끝나 보이스가 반납된 뒤라면 이 핸들만 실패한다.
        // 나머지 트랙까지 멈출 이유는 없다.
        debugPrint('seek 실패: $e');
      }
    }
    position.value = clamped;
  }

  void seekBy(Duration delta) => seek(position.value + delta);

  void setVolume(String id, double value) {
    _volumes[id] = value;
    _applyVolume(id);
    _notify();
  }

  /// 음소거와 솔로는 한 트랙에서 동시에 켜지지 않는다.
  ///
  /// 솔로는 "이것만 들린다", 음소거는 "이것은 안 들린다" 라 서로 반대다.
  /// 둘 다 켜진 상태는 뜻이 성립하지 않으므로, 하나를 켜면 다른 하나는
  /// 꺼진다.
  void toggleMute(String id) {
    if (!_muted.remove(id)) {
      _muted.add(id);
      if (_soloed == id) _soloed = null;
    }
    _applyAllVolumes();
    _notify();
  }

  /// 솔로는 한 번에 하나만. 같은 트랙을 다시 누르면 해제된다.
  void toggleSolo(String id) {
    if (_soloed == id) {
      _soloed = null;
    } else {
      _soloed = id;
      _muted.remove(id);
    }
    _applyAllVolumes();
    _notify();
  }

  void setLooping(bool value) {
    _looping = value;
    _notify();
  }

  void setSemitones(int value) {
    final int clamped = value.clamp(-maxSemitones, maxSemitones);
    _semitones = clamped;
    _applyPitch();
    _notify();
  }

  /// 지금 키 값에 맞게 필터를 켜거나 끈다.
  ///
  /// 원키(0반음)에서는 아예 끈다. 켜 두면 아무것도 바꾸지 않는 상태에서도
  /// 소리가 깎이기 때문이다. 키를 건드리지 않은 사람은 원음을 그대로
  /// 들어야 한다.
  void _applyPitch() {
    if (!_pitchAvailable || _disposed) return;
    try {
      final filter = _soloud.filters.pitchShiftFilter;
      if (_semitones == 0) {
        if (filter.isActive) filter.deactivate();
        return;
      }
      if (!filter.isActive) filter.activate();
      filter.semitones.value = _semitones.toDouble();
    } catch (_) {
      _pitchAvailable = false;
    }
  }

  double _effectiveVolume(String id) =>
      isAudible(id) ? (_volumes[id] ?? 1.0) : 0.0;

  void _applyVolume(String id) {
    final SoundHandle? h = _handles[id];
    if (h != null) _soloud.setVolume(h, _effectiveVolume(id));
  }

  void _applyAllVolumes() {
    for (final String id in _handles.keys) {
      _applyVolume(id);
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_disposed || _handles.isEmpty) return;

      // 곡이 끝나면 SoLoud 가 보이스를 반납한다. 핸들이 죽은 걸로 끝을 안다.
      final SoundHandle first = _handles.values.first;
      if (!_soloud.getIsValidVoiceHandle(first)) {
        _onFinished();
        return;
      }
      position.value = _soloud.getPosition(first);
    });
  }

  void _onFinished() {
    if (_disposed) return;
    _ticker?.cancel();
    _handles.clear();
    position.value = Duration.zero;
    _isPlaying = false;
    _notify();
    if (_looping) play();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    for (final SoundHandle h in _handles.values) {
      _soloud.stop(h);
    }
    _handles.clear();
    for (final AudioSource s in _sources.values) {
      unawaited(_soloud.disposeSource(s));
    }
    _sources.clear();
    position.dispose();
    super.dispose();
  }
}
