import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/bpm_result.dart';
import '../services/api_service.dart';
import 'analysis_tab.dart';

// ── 결과 탭 모드 ──────────────────────────────────────────────
enum ResultMode { bpm, track, empty }

class ResultTab extends StatefulWidget {
  final List<TrackResult> tracks;
  final String? audioFilename;
  final Uint8List? audioBytes;
  final String? bpmJobId;
  final BpmResult? bpmResult;
  final ResultMode? preferredMode;

  const ResultTab({
    super.key,
    required this.tracks,
    this.audioFilename,
    this.audioBytes,
    this.bpmJobId,
    this.bpmResult,
    this.preferredMode,
  });

  @override
  State<ResultTab> createState() => _ResultTabState();
}

class _ResultTabState extends State<ResultTab> {
  static const _purple = Color(0xFF8B5CF6);
  static const _blue = Color(0xFF3B82F6);
  static const _red = Color(0xFFEF4444);

  BpmResult? _bpmResult;
  bool _isLoading = false;

  // ── BPM 오디오 재생 ──────────────────────────────────────────
  final _player = AudioPlayer();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _sourceLoaded = false;

  // ── 트랙 오디오 재생 ─────────────────────────────────────────
  final _trackPlayer = AudioPlayer();
  Duration _trackPosition = Duration.zero;
  Duration _trackDuration = Duration.zero;
  bool _trackIsPlaying = false;
  String? _playingTrackUrl;

  double get _playPosition => _duration.inMilliseconds > 0
      ? _position.inMilliseconds / _duration.inMilliseconds
      : 0.0;

  @override
  void initState() {
    super.initState();
    _bpmResult = widget.bpmResult;
    if (_bpmResult == null && widget.bpmJobId != null) {
      _loadBpmResult();
    }
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _isPlaying = s == PlayerState.playing);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _position = Duration.zero; _sourceLoaded = false; });
    });

    _trackPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _trackPosition = p);
    });
    _trackPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _trackDuration = d);
    });
    _trackPlayer.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _trackIsPlaying = s == PlayerState.playing);
    });
    _trackPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _trackPosition = Duration.zero; _trackIsPlaying = false; });
    });
  }

  @override
  void didUpdateWidget(ResultTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bpmResult != null && _bpmResult == null) {
      setState(() => _bpmResult = widget.bpmResult);
    } else if (widget.bpmJobId != null &&
        widget.bpmJobId != oldWidget.bpmJobId &&
        _bpmResult == null) {
      _loadBpmResult();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    _trackPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadBpmResult() async {
    setState(() => _isLoading = true);
    try {
      final data = await ApiService().getBpmResult(widget.bpmJobId!);
      if (mounted) setState(() => _bpmResult = BpmResult.fromJson(data));
    } catch (_) {} finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── 트랙 재생/정지 ────────────────────────────────────────────
  Future<void> _playTrackAudio(String url) async {
    if (_playingTrackUrl == url) {
      if (_trackIsPlaying) {
        await _trackPlayer.pause();
      } else {
        await _trackPlayer.resume();
      }
    } else {
      await _trackPlayer.stop();
      setState(() {
        _playingTrackUrl = url;
        _trackPosition = Duration.zero;
        _trackDuration = Duration.zero;
      });
      await _trackPlayer.play(UrlSource(url));
    }
  }

  double get _trackPlayPosition => _trackDuration.inMilliseconds > 0
      ? _trackPosition.inMilliseconds / _trackDuration.inMilliseconds
      : 0.0;

  // ── BPM 재생/정지 토글 ────────────────────────────────────────
  Future<void> _togglePlay() async {
    if (widget.audioBytes == null) return;
    if (_isPlaying) {
      await _player.pause();
    } else if (_sourceLoaded) {
      await _player.resume();
    } else {
      await _player.play(BytesSource(widget.audioBytes!));
      _sourceLoaded = true;
    }
  }

  ResultMode get _mode {
    if (widget.preferredMode == ResultMode.track && widget.tracks.isNotEmpty) return ResultMode.track;
    if (widget.preferredMode == ResultMode.bpm && _bpmResult != null) return ResultMode.bpm;
    if (_bpmResult != null) return ResultMode.bpm;
    if (widget.tracks.isNotEmpty) return ResultMode.track;
    return ResultMode.empty;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF8B5CF6)),
      );
    }

    switch (_mode) {
      case ResultMode.bpm:
        return _buildBpmResult();
      case ResultMode.track:
        return _buildTrackResult();
      case ResultMode.empty:
        return _buildEmpty();
    }
  }

  // ── 빈 화면 ────────────────────────────────────────────────
  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.hourglass_empty_rounded, size: 48, color: Color(0xFFD1D5DB)),
          SizedBox(height: 16),
          Text('분석 후 결과가 표시됩니다',
              style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
        ],
      ),
    );
  }

  // ── BPM 결과 화면 ──────────────────────────────────────────
  Widget _buildBpmResult() {
    final result = _bpmResult!;
    final totalTime = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds / 1000.0
        : (result.bpmData.isNotEmpty ? result.bpmData.last.time : 1.0);
    final currentTime = _position.inMilliseconds / 1000.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 헤더 ────────────────────────────────────────────
          const Text('BPM 분석 결과',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (widget.audioFilename != null) ...[
            const SizedBox(height: 2),
            Text(widget.audioFilename!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          ],
          const SizedBox(height: 16),

          // ── 전체 BPM 수치 ────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('전체 BPM',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(result.baseBpm.toInt().toString(),
                        style: const TextStyle(
                            fontSize: 52,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                            height: 1.0)),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8, left: 4),
                      child: Text('BPM',
                          style: TextStyle(
                              fontSize: 14,
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w500)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 평균/최고/최저 칩
                Row(
                  children: [
                    _StatChip(label: '평균', value: result.avgBpm.toInt().toString(), color: const Color(0xFFEDE9FE), textColor: _purple),
                    const SizedBox(width: 8),
                    _StatChip(label: '최고', value: result.maxBpm.toInt().toString(), color: const Color(0xFFFFEDED), textColor: _red),
                    const SizedBox(width: 8),
                    _StatChip(label: '최저', value: result.minBpm.toInt().toString(), color: const Color(0xFFEFF6FF), textColor: _blue),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── BPM 그래프 ───────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('실시간 BPM',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 140,
                  child: _BpmGraph(
                    bpmData: result.bpmData,
                    baseBpm: result.baseBpm,
                    playPosition: _playPosition,
                  ),
                ),
                const SizedBox(height: 16),

                // ── 재생 슬라이더 ────────────────────────────
                Row(
                  children: [
                    GestureDetector(
                      onTap: _togglePlay,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: _purple,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: _purple,
                          inactiveTrackColor: const Color(0xFFE5E7EB),
                          thumbColor: _purple,
                        ),
                        child: Slider(
                          value: _playPosition,
                          onChanged: _duration.inMilliseconds > 0
                              ? (v) {
                                  final target = Duration(
                                    milliseconds: (v * _duration.inMilliseconds).round(),
                                  );
                                  _player.seek(target);
                                }
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 현재시간 / 전체시간
                    Text(
                      '${_formatTime(currentTime)} / ${_formatTime(totalTime)}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _purple),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── 템포 변화 구간 ───────────────────────────────────
          if (result.deviationSections.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('템포 변화 구간',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  ...result.deviationSections.map(
                    (s) => _DeviationRow(section: s, baseBpm: result.baseBpm),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── 트랙 분리 결과 화면 ────────────────────────────────────
  Widget _buildTrackResult() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('트랙 분리 결과',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (widget.audioFilename != null) ...[
            const SizedBox(height: 4),
            Text(widget.audioFilename!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          ],
          const SizedBox(height: 16),
          ...widget.tracks.map((track) => _buildTrackCard(track)),
        ],
      ),
    );
  }

  Widget _buildTrackCard(TrackResult track) {
    final isActive = _playingTrackUrl == track.url;
    final isPlaying = isActive && _trackIsPlaying;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F7FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive ? _purple.withValues(alpha: 0.4) : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 36, height: 36,
                decoration: const BoxDecoration(
                  color: Color(0xFFEDE9FE), shape: BoxShape.circle),
                child: Icon(track.icon, color: _purple, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(track.label,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              GestureDetector(
                onTap: () => _playTrackAudio(track.url),
                child: Container(
                  width: 36, height: 36,
                  decoration: const BoxDecoration(color: _purple, shape: BoxShape.circle),
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white, size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => _launchUrl(context, track.url),
                child: const Icon(Icons.download_rounded, color: Color(0xFF6B7280), size: 24),
              ),
            ],
          ),
          if (isActive) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: _purple,
                      inactiveTrackColor: const Color(0xFFE5E7EB),
                      thumbColor: _purple,
                    ),
                    child: Slider(
                      value: _trackPlayPosition,
                      onChanged: _trackDuration.inMilliseconds > 0
                          ? (v) => _trackPlayer.seek(Duration(
                              milliseconds: (v * _trackDuration.inMilliseconds).round()))
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_formatTime(_trackPosition.inMilliseconds / 1000)} / ${_formatTime(_trackDuration.inMilliseconds / 1000)}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _purple),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _launchUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('열 수 없습니다')),
      );
    }
  }

  String _formatTime(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(1, '0');
    final s = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ── BPM 그래프 위젯 ──────────────────────────────────────────
class _BpmGraph extends StatelessWidget {
  final List<BpmPoint> bpmData;
  final double baseBpm;
  final double playPosition;

  const _BpmGraph({
    required this.bpmData,
    required this.baseBpm,
    required this.playPosition,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BpmGraphPainter(
        bpmData: bpmData,
        baseBpm: baseBpm,
        playPosition: playPosition,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _BpmGraphPainter extends CustomPainter {
  final List<BpmPoint> bpmData;
  final double baseBpm;
  final double playPosition;

  static const _purple = Color(0xFF8B5CF6);
  static const _grey = Color(0xFFE5E7EB);

  _BpmGraphPainter({
    required this.bpmData,
    required this.baseBpm,
    required this.playPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bpmData.isEmpty) return;

    final maxTime = bpmData.last.time;
    final allBpms = bpmData.map((e) => e.bpm).toList();
    final minBpm = allBpms.reduce((a, b) => a < b ? a : b) - 5;
    final maxBpm = allBpms.reduce((a, b) => a > b ? a : b) + 5;
    final bpmRange = maxBpm - minBpm;

    // Y축 레이블 영역
    const leftPad = 36.0;
    const bottomPad = 20.0;
    final graphW = size.width - leftPad;
    final graphH = size.height - bottomPad;

    // Y축 가이드라인 + 레이블
    final gridPaint = Paint()..color = _grey..strokeWidth = 1;
    final labelStyle = const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF));

    for (int i = 0; i <= 3; i++) {
      final bpmVal = minBpm + (bpmRange * i / 3);
      final y = graphH - (graphH * (bpmVal - minBpm) / bpmRange);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
      _drawText(canvas, bpmVal.toInt().toString(), Offset(0, y - 6), labelStyle);
    }

    // X축 레이블
    final xLabels = _generateTimeLabels(maxTime);
    for (final t in xLabels) {
      final x = leftPad + graphW * (t / maxTime);
      _drawText(canvas, _formatTime(t), Offset(x - 10, graphH + 4), labelStyle);
    }

    // 기준선 (baseBpm)
    final baseY = graphH - (graphH * (baseBpm - minBpm) / bpmRange);
    final basePaint = Paint()
      ..color = _grey
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final dashPath = Path()..moveTo(leftPad, baseY);
    for (double x = leftPad; x < size.width; x += 8) {
      dashPath.lineTo(x + 4, baseY);
      dashPath.moveTo(x + 8, baseY);
    }
    canvas.drawPath(dashPath, basePaint);

    // BPM 곡선
    final linePaint = Paint()
      ..color = _purple
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (int i = 0; i < bpmData.length; i++) {
      final x = leftPad + graphW * (bpmData[i].time / maxTime);
      final y = graphH - (graphH * (bpmData[i].bpm - minBpm) / bpmRange);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, linePaint);

    // 현재 재생 위치 점 + 세로선
    final curTime = playPosition * maxTime;
    final curX = leftPad + graphW * playPosition;
    // 가장 가까운 BPM 찾기
    final curBpmPoint = bpmData.reduce((a, b) =>
        (a.time - curTime).abs() < (b.time - curTime).abs() ? a : b);
    final curY = graphH - (graphH * (curBpmPoint.bpm - minBpm) / bpmRange);

    // 세로선
    canvas.drawLine(
      Offset(curX, 0),
      Offset(curX, graphH),
      Paint()..color = _grey..strokeWidth = 1,
    );

    // 점
    canvas.drawCircle(
      Offset(curX, curY),
      6,
      Paint()..color = _purple,
    );

    // 현재 BPM 레이블
    _drawText(
      canvas,
      '현재 ${curBpmPoint.bpm.toInt()}',
      Offset(curX + 6, curY - 14),
      const TextStyle(fontSize: 10, color: Color(0xFF6B7280)),
    );
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  List<double> _generateTimeLabels(double maxTime) {
    final interval = maxTime <= 60 ? 10.0 : maxTime <= 180 ? 30.0 : 60.0;
    final labels = <double>[];
    for (double t = 0; t <= maxTime; t += interval) labels.add(t);
    return labels;
  }

  String _formatTime(double seconds) {
    final m = (seconds ~/ 60).toInt();
    final s = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  bool shouldRepaint(covariant _BpmGraphPainter old) =>
      old.playPosition != playPosition || old.bpmData != bpmData;
}

// ── 통계 칩 ──────────────────────────────────────────────────
class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color textColor;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: textColor.withOpacity(0.7))),
          const SizedBox(width: 4),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: textColor)),
        ],
      ),
    );
  }
}

// ── 템포 변화 구간 행 ─────────────────────────────────────────
class _DeviationRow extends StatelessWidget {
  final DeviationSection section;
  final double baseBpm;

  const _DeviationRow({required this.section, required this.baseBpm});

  @override
  Widget build(BuildContext context) {
    final diff = section.deviation(baseBpm);
    final isFaster = section.isFaster(baseBpm);
    final diffColor = isFaster ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final diffText = isFaster ? '+${diff.toInt()} BPM' : '${diff.toInt()} BPM';
    final label = isFaster ? '빨라짐' : '느려짐';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: diffColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            '${section.startLabel} – ${section.endLabel}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
          ),
          const SizedBox(width: 12),
          Text(diffText,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: diffColor)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: diffColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(label,
                style: TextStyle(fontSize: 11, color: diffColor)),
          ),
          const Spacer(),
          const Icon(Icons.chevron_right_rounded,
              size: 16, color: Color(0xFFD1D5DB)),
        ],
      ),
    );
  }
}