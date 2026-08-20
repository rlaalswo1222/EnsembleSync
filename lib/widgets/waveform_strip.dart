import 'package:flutter/material.dart';

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
    this.peakScale = 255,
    this.barWidth = 2.0,
    this.barGap = 2.0,
  });

  /// 0 ~ [peakScale] 범위의 구간별 최대 진폭.
  final List<int> peaks;

  /// 0.0 ~ 1.0 재생 진행률.
  final double progress;

  final Color color;
  final int peakScale;
  final double barWidth;
  final double barGap;

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
            barWidth: widget.barWidth,
            slot: slot,
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
    required this.barWidth,
    required this.slot,
  });

  final List<double> bars;
  final double progress;
  final Color color;
  final double barWidth;
  final double slot;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final Paint played = Paint()..color = color;
    // 지나간 부분과 남은 부분을 같은 색의 농도 차이로만 나눈다. 다른 색을
    // 섞으면 트랙 구분색과 충돌한다.
    final Paint upcoming = Paint()..color = color.withValues(alpha: 0.28);

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
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.color != color ||
      !identical(old.bars, bars);
}
