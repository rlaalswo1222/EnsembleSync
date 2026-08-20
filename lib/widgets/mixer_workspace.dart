import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/track_analysis.dart';
import '../models/track_result.dart';
import '../services/api_service.dart';
import '../services/mixer_engine.dart';
import '../services/platform_download.dart';
import 'chord_timeline.dart';
import 'waveform_strip.dart';

/// 분리된 트랙을 한 화면에서 함께 다루는 작업 화면.
///
/// 재생 버튼은 화면에 하나뿐이고 4트랙이 같이 움직인다. 트랙마다 조절하는
/// 것은 볼륨과 음소거/솔로뿐이다.
class MixerWorkspace extends StatefulWidget {
  const MixerWorkspace({
    super.key,
    required this.tracks,
    this.analysisUrl,
    this.bpm,
  });

  final List<TrackResult> tracks;

  /// 서버가 분리와 함께 만들어 둔 analysis.json 주소. 없을 수 있다.
  final String? analysisUrl;

  /// 별도 BPM 분석 결과. 없으면 상단에 표시하지 않는다.
  final double? bpm;

  @override
  State<MixerWorkspace> createState() => _MixerWorkspaceState();
}

class _MixerWorkspaceState extends State<MixerWorkspace> {
  static const Color _primary = Color(0xFF0F766E);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _muted = Color(0xFF6B7280);
  static const Color _ink = Color(0xFF111827);

  /// 트랙별 색. 파형만 보고도 어느 트랙인지 구분되게 한다.
  static const Map<String, Color> _trackColors = <String, Color>{
    'vocals': Color(0xFF0F766E),
    'drums': Color(0xFFC2410C),
    'bass': Color(0xFF1D4ED8),
    'other': Color(0xFF7E22CE),
  };

  /// 화면 좌우 여백 + 카드 안쪽 여백. 재생선과 파형의 시작점을 맞추는 데 쓴다.
  static const double _outerPad = 16;
  static const double _cardPad = 16;
  static const double _waveInset = _outerPad + _cardPad;

  final MixerEngine _engine = MixerEngine();
  TrackAnalysis? _analysis;

  /// 지금 내려받는 중인 트랙의 주소. 같은 버튼을 두 번 누르는 것을 막는다.
  String? _savingUrl;

  @override
  void initState() {
    super.initState();
    _engine.addListener(_onEngineChanged);
    _engine.load(<String, String>{
      for (final TrackResult t in widget.tracks) _stemOf(t): t.playbackUrl,
    });
    _loadAnalysis();
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    super.dispose();
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
  }

  /// analysis.json 의 피크는 스템 이름으로 묶여 있다. 파일명에서 그 이름을
  /// 되찾는다. 확장자를 떼므로 wav 든 mp3 든 같은 값이 나온다.
  String _stemOf(TrackResult t) {
    final String name = Uri.parse(t.url).pathSegments.last;
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  Future<void> _loadAnalysis() async {
    final String? url = widget.analysisUrl;
    if (url == null) return;
    try {
      final http.Response res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200 || !mounted) return;
      setState(() => _analysis = TrackAnalysis.tryParse(res.body));
    } catch (_) {
      // 파형과 코드가 없어도 재생은 된다. 조용히 넘어간다.
    }
  }

  double get _totalSeconds {
    final double fromEngine = _engine.length.inMilliseconds / 1000;
    if (fromEngine > 0) return fromEngine;
    return _analysis?.duration ?? 0;
  }

  void _seekToFraction(double fraction) {
    final double total = _totalSeconds;
    if (total <= 0) return;
    _engine.seek(
      Duration(milliseconds: (fraction.clamp(0.0, 1.0) * total * 1000).round()),
    );
  }

  String _extensionOf(TrackResult track) {
    final String? ext =
        Uri.tryParse(track.url)?.pathSegments.last.split('.').last;
    if (ext == null || ext.length > 5) return 'wav';
    return ext.toLowerCase();
  }

  String _filenameOf(TrackResult track) {
    final String safe = track.label.replaceAll(RegExp(r'[\/:*?"<>|\s]+'), '_');
    return '${safe}_track.${_extensionOf(track)}';
  }

  Future<void> _downloadTrack(TrackResult track) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String filename = _filenameOf(track);
    setState(() => _savingUrl = track.url);

    try {
      final Uint8List bytes = await ApiService().downloadTrack(track.url);
      if (!mounted) return;

      messenger.showSnackBar(
        const SnackBar(content: Text('저장할 위치를 선택해주세요.')),
      );

      final String? savedPath = await PlatformDownload.saveBytes(
        bytes: bytes,
        filename: filename,
        allowedExtensions: <String>[_extensionOf(track)],
        dialogTitle: '트랙 저장 위치 선택',
      );
      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            savedPath == null ? '트랙 저장이 취소되었습니다.' : '저장 완료: $savedPath',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('트랙 다운로드 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _savingUrl = null);
    }
  }

  static String _fmt(Duration d) {
    final String m = d.inMinutes.toString();
    final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_engine.error != null) {
      return _Message(
        icon: Icons.error_outline_rounded,
        text: '오디오를 불러오지 못했습니다\n${_engine.error}',
      );
    }
    if (!_engine.isReady) {
      return _Message(
        icon: Icons.graphic_eq_rounded,
        text: _engine.loadingLabel.isEmpty ? '준비 중' : _engine.loadingLabel,
        spinner: true,
      );
    }

    return Column(
      children: <Widget>[
        _buildInfoBar(),
        Expanded(child: _buildTrackStack()),
        if (_analysis?.hasChords ?? false) _buildChords(),
        _buildTransport(),
      ],
    );
  }

  // ── 상단 정보 바 ────────────────────────────────────────────

  Widget _buildInfoBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: <Widget>[
            Expanded(child: _buildBpmCell()),
            const VerticalDivider(width: 1, color: _border),
            Expanded(flex: 2, child: _buildKeyCell()),
          ],
        ),
      ),
    );
  }

  Widget _buildBpmCell() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: <Widget>[
          const Text('BPM', style: TextStyle(fontSize: 11, color: _muted)),
          const SizedBox(height: 2),
          Text(
            widget.bpm == null ? '—' : widget.bpm!.round().toString(),
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: widget.bpm == null ? const Color(0xFFD1D5DB) : _primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyCell() {
    final KeyEstimate? key = _analysis?.key;
    final int shift = _engine.semitones;
    final bool canShift = _engine.pitchAvailable;

    final String display;
    if (key != null && key.isValid) {
      display =
          shift == 0 ? key.tonic! : '${key.tonic!} → ${key.transposed(shift)}';
    } else {
      display = shift == 0 ? '—' : (shift > 0 ? '+$shift' : '$shift');
    }

    // 나란한조는 구성음이 같아 기계가 확신을 못 준다. 숨기지 말고 같이 띄운다.
    final String sub;
    if (shift != 0) {
      sub = '${shift > 0 ? '+' : ''}$shift 반음';
    } else if (key != null && key.isValid && key.isAmbiguous) {
      sub = '${key.label} 또는 ${key.relativeLabel}';
    } else if (key != null && key.isValid) {
      sub = key.label;
    } else {
      sub = '분석 없음';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('KEY', style: TextStyle(fontSize: 11, color: _muted)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _StepButton(
                icon: Icons.remove,
                onTap: canShift && shift > -MixerEngine.maxSemitones
                    ? () => _engine.setSemitones(shift - 1)
                    : null,
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 92),
                child: Text(
                  display,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _ink,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _StepButton(
                icon: Icons.add,
                onTap: canShift && shift < MixerEngine.maxSemitones
                    ? () => _engine.setSemitones(shift + 1)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 2),
          GestureDetector(
            onTap: shift == 0 ? null : () => _engine.setSemitones(0),
            child: Text(
              shift == 0 ? sub : '$sub · 원키로',
              style: TextStyle(
                fontSize: 11,
                color: shift == 0 ? _muted : _primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 트랙 스택 ──────────────────────────────────────────────

  Widget _buildTrackStack() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double laneWidth = constraints.maxWidth - _waveInset * 2;

        void seekFromX(double dx) {
          if (laneWidth <= 0) return;
          _seekToFraction((dx - _waveInset) / laneWidth);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) => seekFromX(d.localPosition.dx),
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              seekFromX(d.localPosition.dx),
          child: Stack(
            children: <Widget>[
              ListView(
                padding:
                    const EdgeInsets.fromLTRB(_outerPad, 12, _outerPad, 12),
                physics: const ClampingScrollPhysics(),
                children: <Widget>[
                  for (final TrackResult t in widget.tracks) _buildCard(t),
                ],
              ),
              _buildPlayhead(laneWidth),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlayhead(double laneWidth) {
    return ValueListenableBuilder<Duration>(
      valueListenable: _engine.position,
      builder: (BuildContext context, Duration pos, _) {
        final double total = _totalSeconds;
        final double fraction = total <= 0
            ? 0
            : (pos.inMilliseconds / 1000 / total).clamp(0.0, 1.0);
        return Positioned(
          left: _waveInset + laneWidth * fraction - 1,
          top: 0,
          bottom: 0,
          width: 2,
          child: IgnorePointer(child: Container(color: _ink)),
        );
      },
    );
  }

  Widget _buildCard(TrackResult track) {
    final String stem = _stemOf(track);
    final Color color = _trackColors[stem] ?? _primary;
    final bool audible = _engine.isAudible(stem);
    final List<int> peaks = _analysis?.peaks[stem] ?? const <int>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedOpacity(
        // 소리가 죽은 트랙은 카드째로 흐려진다. 작은 버튼 색만 바꾸는 것보다
        // 훨씬 빨리 읽힌다.
        opacity: audible ? 1.0 : 0.4,
        duration: const Duration(milliseconds: 150),
        child: Container(
          padding: const EdgeInsets.all(_cardPad),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      track.label,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _ink,
                      ),
                    ),
                  ),
                  _ToggleCircle(
                    label: 'M',
                    active: _engine.isMuted(stem),
                    color: color,
                    onTap: () => _engine.toggleMute(stem),
                  ),
                  const SizedBox(width: 8),
                  _ToggleCircle(
                    label: 'S',
                    active: _engine.isSoloed(stem),
                    color: color,
                    onTap: () => _engine.toggleSolo(stem),
                  ),
                  const SizedBox(width: 4),
                  _DownloadButton(
                    busy: _savingUrl == track.url,
                    onTap:
                        _savingUrl == null ? () => _downloadTrack(track) : null,
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: color,
                  inactiveTrackColor: const Color(0xFFE5E7EB),
                  thumbColor: color,
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 7),
                ),
                child: Slider(
                  value: _engine.volumeOf(stem),
                  onChanged: (double v) => _engine.setVolume(stem, v),
                ),
              ),
              SizedBox(
                height: 36,
                child: peaks.isEmpty
                    ? const _NoWaveform()
                    : ValueListenableBuilder<Duration>(
                        valueListenable: _engine.position,
                        builder: (BuildContext context, Duration pos, _) {
                          final double total = _totalSeconds;
                          return WaveformStrip(
                            peaks: peaks,
                            peakScale: _analysis?.peakScale ?? 255,
                            color: color,
                            progress: total <= 0
                                ? 0
                                : (pos.inMilliseconds / 1000 / total)
                                    .clamp(0.0, 1.0),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 코드 ──────────────────────────────────────────────────

  Widget _buildChords() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: ValueListenableBuilder<Duration>(
        valueListenable: _engine.position,
        builder: (BuildContext context, Duration pos, _) => ChordTimeline(
          chords: _analysis!.chords,
          seconds: pos.inMilliseconds / 1000,
          primary: _primary,
        ),
      ),
    );
  }

  // ── 하단 트랜스포트 ─────────────────────────────────────────

  Widget _buildTransport() {
    final Duration total =
        Duration(milliseconds: (_totalSeconds * 1000).round());

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ValueListenableBuilder<Duration>(
            valueListenable: _engine.position,
            builder: (BuildContext context, Duration pos, _) => Text.rich(
              TextSpan(
                children: <TextSpan>[
                  TextSpan(
                    text: _fmt(pos),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _ink,
                    ),
                  ),
                  TextSpan(
                    text: ' / ${_fmt(total)}',
                    style: const TextStyle(color: _muted),
                  ),
                ],
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              const SizedBox(width: 44),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton(
                      iconSize: 30,
                      color: _ink,
                      onPressed: () =>
                          _engine.seekBy(const Duration(seconds: -10)),
                      icon: const Icon(Icons.replay_10_rounded),
                    ),
                    const SizedBox(width: 12),
                    _PlayButton(
                      playing: _engine.isPlaying,
                      onTap: _engine.togglePlay,
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      iconSize: 30,
                      color: _ink,
                      onPressed: () =>
                          _engine.seekBy(const Duration(seconds: 10)),
                      icon: const Icon(Icons.forward_10_rounded),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 44,
                child: IconButton(
                  onPressed: () => _engine.setLooping(!_engine.looping),
                  color: _engine.looping ? _primary : const Color(0xFF9CA3AF),
                  icon: const Icon(Icons.repeat_rounded),
                  tooltip: _engine.looping ? '반복 켜짐' : '반복 꺼짐',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onTap != null;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? const Color(0xFF9CA3AF) : const Color(0xFFE5E7EB),
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: enabled ? const Color(0xFF374151) : const Color(0xFFD1D5DB),
        ),
      ),
    );
  }
}

class _ToggleCircle extends StatelessWidget {
  const _ToggleCircle({
    required this.label,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? color : Colors.transparent,
          border: Border.all(color: active ? color : const Color(0xFFD1D5DB)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: active ? Colors.white : const Color(0xFF9CA3AF),
          ),
        ),
      ),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: busy ? null : onTap,
      radius: 22,
      child: SizedBox(
        width: 30,
        height: 30,
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(7),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF9CA3AF),
                ),
              )
            : const Icon(
                Icons.download_rounded,
                size: 20,
                color: Color(0xFF9CA3AF),
              ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 40,
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF0F766E),
        ),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 34,
        ),
      ),
    );
  }
}

class _NoWaveform extends StatelessWidget {
  const _NoWaveform();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '파형 정보 없음',
        style: TextStyle(fontSize: 11, color: Color(0xFFD1D5DB)),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.spinner = false,
  });

  final IconData icon;
  final String text;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (spinner)
            const CircularProgressIndicator(color: Color(0xFF0F766E))
          else
            Icon(icon, size: 44, color: const Color(0xFFD1D5DB)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
          ),
        ],
      ),
    );
  }
}
