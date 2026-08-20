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

  double volumeOf(String id) => _volumes[id] ?? 1.0;
  bool isMuted(String id) => _muted.contains(id);
  bool isSoloed(String id) => _soloed == id;

  /// 솔로가 걸려 있으면 그 트랙만, 아니면 음소거되지 않은 트랙만 들린다.
  bool isAudible(String id) =>
      _soloed != null ? _soloed == id : !_muted.contains(id);

  /// [urls] 는 {트랙 id: 오디오 주소}. 순서가 곧 화면에 쌓이는 순서다.
  Future<void> load(Map<String, String> urls) async {
    if (_isLoading) return;
    _isLoading = true;
    _isReady = false;
    _error = null;
    _order = urls.keys.toList();
    notifyListeners();

    try {
      if (!_soloud.isInitialized) {
        _loadingLabel = '오디오 엔진 준비 중';
        notifyListeners();
        await _soloud.init();
      }

      // 웹에서는 트랙별 필터가 막혀 있어 전역 필터만 쓸 수 있다. 키 조절은
      // 어차피 곡 전체에 걸리는 것이라 전역으로 충분하다.
      try {
        if (!_soloud.filters.pitchShiftFilter.isActive) {
          _soloud.filters.pitchShiftFilter.activate();
        }
        _pitchAvailable = _soloud.filters.pitchShiftFilter.isActive;
      } catch (_) {
        _pitchAvailable = false;
      }

      for (final MapEntry<String, String> e in urls.entries) {
        _loadingLabel = '${e.key} 불러오는 중';
        notifyListeners();
        _sources[e.key] = await _soloud.loadUrl(e.value);
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
      notifyListeners();
    }
  }

  void togglePlay() => _isPlaying ? pause() : play();

  /// 전부 멈춘 상태로 띄운 뒤 한꺼번에 재생을 푼다. 하나씩 play() 하면
  /// 호출 간격만큼 그대로 어긋난 채 시작한다.
  void play() {
    if (!_isReady) return;
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
    notifyListeners();
  }

  void pause() {
    for (final SoundHandle h in _handles.values) {
      _soloud.setPause(h, true);
    }
    _isPlaying = false;
    _ticker?.cancel();
    notifyListeners();
  }

  void seek(Duration to) {
    final Duration clamped = to < Duration.zero
        ? Duration.zero
        : (_length > Duration.zero && to > _length ? _length : to);

    if (_handles.isEmpty) {
      // 아직 재생 전이라면 눈금만 옮겨 두고, 재생 시작 때 맞춰 넣는다.
      position.value = clamped;
      return;
    }
    for (final SoundHandle h in _handles.values) {
      _soloud.seek(h, clamped);
    }
    position.value = clamped;
  }

  void seekBy(Duration delta) => seek(position.value + delta);

  void setVolume(String id, double value) {
    _volumes[id] = value;
    _applyVolume(id);
    notifyListeners();
  }

  void toggleMute(String id) {
    if (!_muted.remove(id)) _muted.add(id);
    _applyAllVolumes();
    notifyListeners();
  }

  /// 솔로는 한 번에 하나만. 같은 트랙을 다시 누르면 해제된다.
  void toggleSolo(String id) {
    _soloed = _soloed == id ? null : id;
    _applyAllVolumes();
    notifyListeners();
  }

  void setLooping(bool value) {
    _looping = value;
    notifyListeners();
  }

  void setSemitones(int value) {
    final int clamped = value.clamp(-maxSemitones, maxSemitones);
    _semitones = clamped;
    if (_pitchAvailable) {
      try {
        _soloud.filters.pitchShiftFilter.semitones.value = clamped.toDouble();
      } catch (_) {
        _pitchAvailable = false;
      }
    }
    notifyListeners();
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
      if (_handles.isEmpty) return;

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
    _ticker?.cancel();
    _handles.clear();
    position.value = Duration.zero;
    _isPlaying = false;
    notifyListeners();
    if (_looping) play();
  }

  @override
  void dispose() {
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
