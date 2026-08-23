import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/stroke.dart';

/// 악보와 그 위의 필기.
///
/// 필기 좌표는 0~1 로 정규화해서 주고받는다. 기기마다 화면이 다르니
/// 픽셀을 그대로 보내면 맞을 리가 없기 때문이다.
///
/// 문제는 무엇을 기준으로 1 로 삼느냐였다. 예전에는 이 위젯이 받은 자리
/// 전체를 기준으로 삼았는데, 악보는 BoxFit.contain 으로 그 안에 들어가
/// 있어서 위아래(또는 좌우)에 남는 여백이 생긴다. 그 여백의 크기가 기기의
/// 화면 비율에 따라 달라진다.
///
/// 세로로 긴 폰에서는 위아래에 띠가 생기고, 가로로 넓은 웹 창에서는 좌우에
/// 생긴다. 그래서 악보의 같은 지점을 짚어도 서로 다른 값이 나갔다.
///
/// 이제 악보가 실제로 그려진 사각형을 기준으로 삼는다. AspectRatio 로 그
/// 사각형을 만들고 그 안에서만 그림을 받는다. 여백은 아예 그리는 영역이
/// 아니게 되므로 계산할 것도 없다.
class ScoreCanvas extends StatefulWidget {
  final Uint8List displayBytes;
  final bool isPdf;
  final int currentPdfPage;
  final int pdfPageCount;
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final void Function(DragStartDetails details, Size canvasSize) onPanStart;
  final void Function(DragUpdateDetails details, Size canvasSize) onPanUpdate;
  final void Function(Size canvasSize) onPanEnd;
  final ValueChanged<int> onPdfPageChanged;

  const ScoreCanvas({
    super.key,
    required this.displayBytes,
    required this.isPdf,
    required this.currentPdfPage,
    required this.pdfPageCount,
    required this.strokes,
    required this.currentStroke,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPdfPageChanged,
  });

  @override
  State<ScoreCanvas> createState() => _ScoreCanvasState();
}

class _ScoreCanvasState extends State<ScoreCanvas> {
  /// 악보의 가로세로 비율. 이걸 알아야 그려질 사각형을 만들 수 있다.
  double? _aspect;

  /// 어떤 바이트로 잰 값인지. 페이지를 넘기면 다시 재야 한다.
  Uint8List? _measured;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(ScoreCanvas old) {
    super.didUpdateWidget(old);
    if (!identical(old.displayBytes, widget.displayBytes)) _measure();
  }

  Future<void> _measure() async {
    final Uint8List bytes = widget.displayBytes;
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final double aspect = frame.image.width / frame.image.height;
      // 크기만 알면 되므로 바로 놓아준다. Image.memory 가 따로 디코드해서
      // 캐시에 담으므로 이걸 들고 있어봐야 메모리만 두 배로 쓴다.
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _aspect = aspect;
        _measured = bytes;
      });
    } catch (_) {
      // 비율을 못 재면 예전처럼 받은 자리 전체를 쓴다. 위치가 조금
      // 어긋나더라도 악보를 아예 못 보는 것보다는 낫다.
      if (!mounted) return;
      setState(() {
        _aspect = null;
        _measured = bytes;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool ready = identical(_measured, widget.displayBytes);
    final double? aspect = ready ? _aspect : null;

    return Stack(
      children: [
        Positioned.fill(
          child: Center(
            child: aspect == null
                // 아직 못 쟀거나 잴 수 없는 악보. 자리 전체에 그린다.
                ? _page(null)
                : AspectRatio(aspectRatio: aspect, child: _page(aspect)),
          ),
        ),
        // 페이지 넘김은 악보 밖 여백에서도 눌려야 한다. 그래서 악보
        // 사각형이 아니라 화면 전체를 기준으로 둔다.
        if (widget.isPdf) ..._buildPdfControls(),
      ],
    );
  }

  /// 악보 한 장과 그 위의 필기. 필기 좌표의 기준이 되는 사각형이다.
  Widget _page(double? aspect) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanStart: (details) => widget.onPanStart(details, size),
          onPanUpdate: (details) => widget.onPanUpdate(details, size),
          onPanEnd: (_) => widget.onPanEnd(size),
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.memory(widget.displayBytes, fit: BoxFit.contain),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _DrawingPainter(
                    strokes: widget.strokes,
                    currentStroke: widget.currentStroke,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildPdfControls() {
    final int currentPdfPage = widget.currentPdfPage;
    final int pdfPageCount = widget.pdfPageCount;
    final ValueChanged<int> onPdfPageChanged = widget.onPdfPageChanged;

    return [
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 56,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: currentPdfPage > 0
              ? () => onPdfPageChanged(currentPdfPage - 1)
              : null,
          child: currentPdfPage > 0
              ? const Align(
                  alignment: Alignment.centerLeft,
                  child: _PageArrow(icon: Icons.chevron_left_rounded),
                )
              : null,
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: 56,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: currentPdfPage < pdfPageCount - 1
              ? () => onPdfPageChanged(currentPdfPage + 1)
              : null,
          child: currentPdfPage < pdfPageCount - 1
              ? const Align(
                  alignment: Alignment.centerRight,
                  child: _PageArrow(icon: Icons.chevron_right_rounded),
                )
              : null,
        ),
      ),
      Positioned(
        bottom: 10,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${currentPdfPage + 1} / $pdfPageCount',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

class _PageArrow extends StatelessWidget {
  final IconData icon;

  const _PageArrow({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    );
  }
}

class _DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;

  const _DrawingPainter({
    required this.strokes,
    required this.currentStroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in [
      ...strokes,
      if (currentStroke != null) currentStroke!
    ]) {
      _drawStroke(canvas, size, stroke);
    }
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, Size size, Stroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..color = stroke.isEraser
          ? Colors.white
          : stroke.isHighlighter
              ? stroke.color.withValues(alpha: 0.28)
              : stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = stroke.isHighlighter ? StrokeCap.square : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;

    final points = stroke.points
        .map((point) => Offset(point.dx * size.width, point.dy * size.height))
        .toList();
    if (points.length == 1) {
      canvas.drawCircle(
        points[0],
        stroke.width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = Path()..moveTo(points[0].dx, points[0].dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter oldDelegate) => true;
}
