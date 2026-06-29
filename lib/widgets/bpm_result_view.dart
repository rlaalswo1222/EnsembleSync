import 'dart:typed_data';
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../models/bpm_result.dart';

class BpmResultView extends StatefulWidget {
  final BpmResult result;
  final String? audioFilename;
  final Uint8List? audioBytes;

  const BpmResultView({
    super.key,
    required this.result,
    this.audioFilename,
    this.audioBytes,
  });

  @override
  State<BpmResultView> createState() => _BpmResultViewState();
}

class _BpmResultViewState extends State<BpmResultView> {
  static const _primary = Color(0xFF0F766E);
  static const _blue = Color(0xFF3B82F6);
  static const _red = Color(0xFFEF4444);

  final _player = AudioPlayer();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _sourceLoaded = false;

  double get _playPosition => _duration.inMilliseconds > 0
      ? _position.inMilliseconds / _duration.inMilliseconds
      : 0.0;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _player.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _position = Duration.zero;
          _sourceLoaded = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(BpmResultView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.audioBytes != oldWidget.audioBytes) {
      unawaited(_player.stop());
      _position = Duration.zero;
      _duration = Duration.zero;
      _isPlaying = false;
      _sourceLoaded = false;
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final totalTime = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds / 1000.0
        : (result.bpmData.isNotEmpty ? result.bpmData.last.time : 1.0);
    final currentTime = _position.inMilliseconds / 1000.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('BPM 분석 결과',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if (widget.audioFilename != null) ...[
            const SizedBox(height: 2),
            Text(widget.audioFilename!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          ],
          const SizedBox(height: 16),
          _buildSummaryCard(result),
          const SizedBox(height: 12),
          _buildGraphCard(context, result, totalTime, currentTime),
          const SizedBox(height: 12),
          if (result.deviationSections.isNotEmpty) _buildDeviationCard(result),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BpmResult result) {
    return Container(
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
              Text(
                result.baseBpm.toInt().toString(),
                style: const TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                  height: 1.0,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  'BPM',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatChip(
                label: '평균',
                value: result.avgBpm.toInt().toString(),
                color: const Color(0xFFCCFBF1),
                textColor: _primary,
              ),
              const SizedBox(width: 8),
              _StatChip(
                label: '최고',
                value: result.maxBpm.toInt().toString(),
                color: const Color(0xFFFFEDED),
                textColor: _red,
              ),
              const SizedBox(width: 8),
              _StatChip(
                label: '최저',
                value: result.minBpm.toInt().toString(),
                color: const Color(0xFFEFF6FF),
                textColor: _blue,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGraphCard(
    BuildContext context,
    BpmResult result,
    double totalTime,
    double currentTime,
  ) {
    return Container(
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
          Row(
            children: [
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: _primary,
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
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: _primary,
                    inactiveTrackColor: const Color(0xFFE5E7EB),
                    thumbColor: _primary,
                  ),
                  child: Slider(
                    value: _playPosition,
                    onChanged: _duration.inMilliseconds > 0
                        ? (value) {
                            final target = Duration(
                              milliseconds:
                                  (value * _duration.inMilliseconds).round(),
                            );
                            _player.seek(target);
                          }
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_formatTime(currentTime)} / ${_formatTime(totalTime)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeviationCard(BpmResult result) {
    return Container(
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
            (section) =>
                _DeviationRow(section: section, baseBpm: result.baseBpm),
          ),
        ],
      ),
    );
  }

  String _formatTime(double seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(1, '0');
    final restSeconds = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$minutes:$restSeconds';
  }
}

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

  static const _primary = Color(0xFF0F766E);
  static const _grey = Color(0xFFE5E7EB);

  _BpmGraphPainter({
    required this.bpmData,
    required this.baseBpm,
    required this.playPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bpmData.isEmpty) return;

    final maxTime = bpmData.last.time <= 0 ? 1.0 : bpmData.last.time;
    final allBpms = bpmData.map((point) => point.bpm).toList();
    final minBpm = allBpms.reduce((a, b) => a < b ? a : b) - 5;
    final maxBpm = allBpms.reduce((a, b) => a > b ? a : b) + 5;
    final bpmRange = maxBpm - minBpm;

    const leftPad = 36.0;
    const bottomPad = 20.0;
    final graphW = size.width - leftPad;
    final graphH = size.height - bottomPad;

    final gridPaint = Paint()
      ..color = _grey
      ..strokeWidth = 1;
    const labelStyle = TextStyle(fontSize: 10, color: Color(0xFF9CA3AF));

    for (var i = 0; i <= 3; i++) {
      final bpmVal = minBpm + (bpmRange * i / 3);
      final y = graphH - (graphH * (bpmVal - minBpm) / bpmRange);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
      _drawText(
          canvas, bpmVal.toInt().toString(), Offset(0, y - 6), labelStyle);
    }

    final xLabels = _generateTimeLabels(maxTime);
    for (final time in xLabels) {
      final x = leftPad + graphW * (time / maxTime);
      _drawText(
          canvas, _formatTime(time), Offset(x - 10, graphH + 4), labelStyle);
    }

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

    final linePaint = Paint()
      ..color = _primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (var i = 0; i < bpmData.length; i++) {
      final x = leftPad + graphW * (bpmData[i].time / maxTime);
      final y = graphH - (graphH * (bpmData[i].bpm - minBpm) / bpmRange);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    final curTime = playPosition * maxTime;
    final curX = leftPad + graphW * playPosition;
    final curBpmPoint = bpmData.reduce(
      (a, b) => (a.time - curTime).abs() < (b.time - curTime).abs() ? a : b,
    );
    final curY = graphH - (graphH * (curBpmPoint.bpm - minBpm) / bpmRange);

    canvas.drawLine(
      Offset(curX, 0),
      Offset(curX, graphH),
      Paint()
        ..color = _grey
        ..strokeWidth = 1,
    );

    canvas.drawCircle(Offset(curX, curY), 6, Paint()..color = _primary);
    _drawText(
      canvas,
      '현재 ${curBpmPoint.bpm.toInt()}',
      Offset(curX + 6, curY - 14),
      const TextStyle(fontSize: 10, color: Color(0xFF6B7280)),
    );
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  List<double> _generateTimeLabels(double maxTime) {
    final interval = maxTime <= 60
        ? 10.0
        : maxTime <= 180
            ? 30.0
            : 60.0;
    final labels = <double>[];
    for (double time = 0; time <= maxTime; time += interval) {
      labels.add(time);
    }
    return labels;
  }

  String _formatTime(double seconds) {
    final minutes = (seconds ~/ 60).toInt();
    final restSeconds = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$minutes:$restSeconds';
  }

  @override
  bool shouldRepaint(covariant _BpmGraphPainter oldDelegate) =>
      oldDelegate.playPosition != playPosition ||
      oldDelegate.bpmData != bpmData;
}

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
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviationRow extends StatelessWidget {
  final DeviationSection section;
  final double baseBpm;

  const _DeviationRow({
    required this.section,
    required this.baseBpm,
  });

  @override
  Widget build(BuildContext context) {
    final diff = section.deviation(baseBpm);
    final isFaster = section.isFaster(baseBpm);
    final diffColor =
        isFaster ? const Color(0xFFEF4444) : const Color(0xFF3B82F6);
    final diffText = isFaster ? '+${diff.toInt()} BPM' : '${diff.toInt()} BPM';
    final label = isFaster ? '빨라짐' : '느려짐';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: diffColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            '${section.startLabel} - ${section.endLabel}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
          ),
          const SizedBox(width: 12),
          Text(
            diffText,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: diffColor,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: diffColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: diffColor),
            ),
          ),
          const Spacer(),
          const Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: Color(0xFFD1D5DB),
          ),
        ],
      ),
    );
  }
}
