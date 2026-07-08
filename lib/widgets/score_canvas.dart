import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/stroke.dart';

class ScoreCanvas extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanStart: (details) => onPanStart(details, size),
          onPanUpdate: (details) => onPanUpdate(details, size),
          onPanEnd: (_) => onPanEnd(size),
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.memory(displayBytes, fit: BoxFit.contain),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _DrawingPainter(
                    strokes: strokes,
                    currentStroke: currentStroke,
                  ),
                ),
              ),
              if (isPdf) ..._buildPdfControls(),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _buildPdfControls() {
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
