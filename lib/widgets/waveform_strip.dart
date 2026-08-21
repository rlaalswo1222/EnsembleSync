import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 트랙 하나의 파형. 재생선을 기준으로 왼쪽은 진하게, 오른쪽은 옅게 칠한다.
///
/// 서버가 주는 피크는 초당 20개라 4분 곡이면 4800개가 넘는다. 화면 폭에
/// 들어가는 막대 수(보통 60~90개)로 줄여서 그리되, 줄이는 계산은 폭이
/// 바뀔 때만 한다. 매 프레임 4800개를 훑으면 재생선이 끊긴다.
class WaveformStrip extends StatefulWidget {
  const WaveformStrip({
    super.key,
    required this.peaks,
    required this.progress,
    required this.color,
    this.upcomingColor,
    this.peakScale = 255,
    this.barWidth = 2.0,
    this.barGap = 2.0,
    this.showPlayhead = true,
  });

  /// 0 ~ [peakScale] 범위의 구간별 최대 진폭.
  final List<int> peaks;

  /// 0.0 ~ 1.0 재생 진행률.
  final double progress;

  /// 이미 지나간 구간의 색.
  final Color color;

  /// 아직 남은 구간의 색. 주지 않으면 [color] 를 옅게 깔아 쓴다.
  final Color? upcomingColor;

  final int peakScale;
  final double barWidth;
  final double barGap;

  /// 재생 위치 표시선. 파형 안에 그려야 카드 경계를 넘지 않는다.
  final bool showPlayhead;

  @override
  State<WaveformStrip> createState() => _WaveformStripState();
}

class _WaveformStripState extends State<WaveformStrip> {
  List<double> _bars = const <double>[];
  int _barsFor = -1;
  List<int>? _barsFrom;

  /// [count] 개 막대로 줄인다. 구간 최댓값을 쓴다. 평균을 쓰면 파형이
  /// 뭉개져서 곡의 리듬이 안 보인다.
  void _rebuild(int count) {
    if (count <= 0 || widget.peaks.isEmpty) {
      _bars = const <double>[];
      _barsFor = count;
      _barsFrom = widget.peaks;
      return;
    }

    final List<int> src = widget.peaks;
    final List<double> out = List<double>.filled(count, 0);
    for (int i = 0; i < count; i++) {
      final int lo = (src.length * i) ~/ count;
      final int hi = (src.length * (i + 1)) ~/ count;
      int top = 0;
      for (int j = lo; j < (hi > lo ? hi : lo + 1) && j < src.length; j++) {
        if (src[j] > top) top = src[j];
      }
      out[i] = top / widget.peakScale;
    }
    _bars = out;
    _barsFor = count;
    _barsFrom = src;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double slot = widget.barWidth + widget.barGap;
        final int count = (constraints.maxWidth / slot).floor();
        if (count != _barsFor || !identical(_barsFrom, widget.peaks)) {
          _rebuild(count);
        }

        return CustomPaint(
          size: Size(constraints.maxWidth, constraints.maxHeight),
          painter: _WaveformPainter(
            bars: _bars,
            progress: widget.progress,
            color: widget.color,
            upcomingColor:
                widget.upcomingColor ?? widget.color.withValues(alpha: 0.28),
            barWidth: widget.barWidth,
            slot: slot,
            showPlayhead: widget.showPlayhead,
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.color,
    required this.upcomingColor,
    required this.barWidth,
    required this.slot,
    required this.showPlayhead,
  });

  final List<double> bars;
  final double progress;
  final Color color;
  final Color upcomingColor;
  final double barWidth;
  final double slot;
  final bool showPlayhead;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final Paint played = Paint()..color = color;
    // 지나간 부분과 남은 부분은 명도 차이로만 나눈다.
    final Paint upcoming = Paint()..color = upcomingColor;

    final double mid = size.height / 2;
    final int playedUpTo = (bars.length * progress).round();

    for (int i = 0; i < bars.length; i++) {
      // 무음 구간도 선으로는 보이게 최소 높이를 준다.
      final double h = (bars[i] * size.height).clamp(1.5, size.height);
      final double x = i * slot;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - h / 2, barWidth, h),
          const Radius.circular(1),
        ),
        i < playedUpTo ? played : upcoming,
      );
    }

    if (!showPlayhead) return;

    // 트랙마다 같은 x 에 그려지므로 세로로 줄이 맞는다. 카드를 관통하는
    // 굵은 선보다 이쪽이 덜 거슬리면서 위치는 그대로 읽힌다.
    final double x = size.width * progress;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x - 1, 0, 2, size.height),
        const Radius.circular(1),
      ),
      Paint()..color = AppColors.accent,
    );
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.upcomingColor != upcomingColor ||
      old.showPlayhead != showPlayhead ||
      !identical(old.bars, bars);
}
