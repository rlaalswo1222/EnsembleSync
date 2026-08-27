import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/stroke.dart';

/// 악보와 그 위의 필기.
///
/// ── 좌표 ────────────────────────────────────────────────
///
/// 필기 좌표는 0~1 로 정규화해서 주고받는다. 기기마다 화면이 다르니 픽셀을
/// 그대로 보내면 맞을 리가 없다.
///
/// 무엇을 1 로 삼느냐가 중요하다. 예전에는 이 위젯이 받은 자리 전체를
/// 기준으로 삼았는데, 악보는 그 안에 BoxFit.contain 으로 들어가므로 여백이
/// 남고 그 크기가 화면 비율에 따라 달라진다. 세로로 긴 폰에서는 위아래에,
/// 가로로 넓은 창에서는 좌우에 띠가 생겨서, 악보의 같은 지점을 짚어도 서로
/// 다른 값이 나갔다.
///
/// 그래서 악보가 실제로 그려지는 사각형을 기준으로 삼는다. AspectRatio 로
/// 그 사각형을 만들면 여백은 아예 그리는 영역이 아니게 된다.
///
/// ── 확대 ────────────────────────────────────────────────
///
/// 태블릿에서 악보를 볼 때 확대가 없으면 작은 음표를 읽기 어렵다.
///
///   손가락 하나   필기
///   손가락 둘     확대 · 이동
///   두 번 두드림  원래 크기로
///
/// 확대해도 좌표는 흔들리지 않는다. 손가락 위치를 화면 좌표에서 악보
/// 좌표로 되돌린 뒤에 정규화하기 때문이다. 확대는 보는 방식일 뿐이고
/// 저장되는 값은 언제나 악보 위의 자리다.
class ScoreCanvas extends StatefulWidget {
  final Uint8List displayBytes;
  final bool isPdf;
  final int currentPdfPage;
  final int pdfPageCount;
  final List<Stroke> strokes;
  final Stroke? currentStroke;

  /// 좌표는 전부 0~1 로 정규화된 악보 위의 자리다.
  final ValueChanged<Offset> onStrokeStart;
  final ValueChanged<Offset> onStrokeUpdate;
  final VoidCallback onStrokeEnd;

  /// 그리다가 손가락이 하나 더 얹혔을 때. 확대하려던 것이므로 그리던 획은
  /// 버린다.
  final VoidCallback onStrokeCancel;

  final ValueChanged<int> onPdfPageChanged;

  const ScoreCanvas({
    super.key,
    required this.displayBytes,
    required this.isPdf,
    required this.currentPdfPage,
    required this.pdfPageCount,
    required this.strokes,
    required this.currentStroke,
    required this.onStrokeStart,
    required this.onStrokeUpdate,
    required this.onStrokeEnd,
    required this.onStrokeCancel,
    required this.onPdfPageChanged,
  });

  @override
  State<ScoreCanvas> createState() => _ScoreCanvasState();
}

class _ScoreCanvasState extends State<ScoreCanvas> {
  static const double _minScale = 1;
  static const double _maxScale = 6;

  /// 악보의 가로세로 비율. 이걸 알아야 그려질 사각형을 만들 수 있다.
  double? _aspect;

  /// 어떤 바이트로 잰 값인지. 페이지를 넘기면 다시 재야 한다.
  Uint8List? _measured;

  /// 확대 배율과 밀린 거리. 악보 좌표 → 화면 좌표는
  /// `화면 = 악보 * _scale + _offset` 이다.
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// 두 손가락 제스처가 시작될 때의 상태.
  double _gestureStartScale = 1;
  Offset _gestureStartFocusOnPage = Offset.zero;

  /// 지금 획을 그리는 중인가.
  bool _drawing = false;

  /// 지금 화면에 닿아 있는 손가락 수.
  ///
  /// ScaleGestureRecognizer 가 알려주는 pointerCount 만으로는 부족하다.
  /// 그리는 중에 손가락이 하나 더 닿으면 제스처를 다시 짜면서 onEnd 를
  /// 부르는데, 그 onEnd 는 손가락이 몇 개인지 알려주지 않는다. 그것을
  /// 진짜 끝으로 알면 확대할 때마다 짧은 자국이 남는다.
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(ScoreCanvas old) {
    super.didUpdateWidget(old);
    if (!identical(old.displayBytes, widget.displayBytes)) {
      // 페이지를 넘기면 확대를 푼다. 앞 페이지의 오른쪽 아래를 보고 있다가
      // 다음 페이지의 같은 자리로 떨어지면 어디를 보는지 알 수 없다.
      _scale = 1;
      _offset = Offset.zero;
      _measure();
    }
  }

  Future<void> _measure() async {
    final Uint8List bytes = widget.displayBytes;
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final double aspect = frame.image.width / frame.image.height;
      // 크기만 알면 되므로 바로 놓아준다. Image.memory 가 따로 디코드해
      // 캐시에 담으므로 이걸 들고 있어봐야 메모리만 두 배로 쓴다.
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _aspect = aspect;
        _measured = bytes;
      });
    } catch (_) {
      // 비율을 못 재면 받은 자리 전체를 쓴다. 위치가 조금 어긋나더라도
      // 악보를 아예 못 보는 것보다는 낫다.
      if (!mounted) return;
      setState(() {
        _aspect = null;
        _measured = bytes;
      });
    }
  }

  // ── 좌표 옮기기 ──────────────────────────────────────────

  /// 화면 위의 자리를 악보 위의 자리로 되돌린다.
  Offset _toPage(Offset viewport) => (viewport - _offset) / _scale;

  /// 악보 위의 자리를 0~1 로 만든다.
  Offset _normalize(Offset page, Size pageSize) => Offset(
        (page.dx / pageSize.width).clamp(0.0, 1.0),
        (page.dy / pageSize.height).clamp(0.0, 1.0),
      );

  /// 악보가 화면 밖으로 빠져나가지 않도록 민 거리를 붙잡는다.
  ///
  /// 이게 없으면 확대한 채로 밀다가 악보가 사라지고 빈 화면만 남는다.
  Offset _clampOffset(Offset offset, Size pageSize) {
    final double scaledW = pageSize.width * _scale;
    final double scaledH = pageSize.height * _scale;

    // 확대한 그림이 보이는 자리보다 작으면 가운데에 둔다.
    final double dx = scaledW <= pageSize.width
        ? (pageSize.width - scaledW) / 2
        : offset.dx.clamp(pageSize.width - scaledW, 0.0);
    final double dy = scaledH <= pageSize.height
        ? (pageSize.height - scaledH) / 2
        : offset.dy.clamp(pageSize.height - scaledH, 0.0);
    return Offset(dx, dy);
  }

  // ── 손가락 ──────────────────────────────────────────────

  void _onScaleStart(ScaleStartDetails d, Size pageSize) {
    if (d.pointerCount >= 2) {
      _beginTransform(d.localFocalPoint);
      return;
    }
    _drawing = true;
    widget.onStrokeStart(_normalize(_toPage(d.localFocalPoint), pageSize));
  }

  void _beginTransform(Offset focal) {
    if (_drawing) {
      // 그리려다 손가락이 하나 더 얹혔다. 확대하려던 것이므로 그리던 획을
      // 버린다. 남겨두면 확대할 때마다 짧은 자국이 생긴다.
      _drawing = false;
      widget.onStrokeCancel();
    }
    _gestureStartScale = _scale;
    _gestureStartFocusOnPage = _toPage(focal);
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size pageSize) {
    if (d.pointerCount >= 2) {
      if (_drawing) _beginTransform(d.localFocalPoint);
      _applyTransform(d, pageSize);
      return;
    }
    if (!_drawing) return;
    widget.onStrokeUpdate(_normalize(_toPage(d.localFocalPoint), pageSize));
  }

  void _applyTransform(ScaleUpdateDetails d, Size pageSize) {
    final double next =
        (_gestureStartScale * d.scale).clamp(_minScale, _maxScale);
    // 손가락 사이의 한 점이 악보의 같은 지점을 계속 붙들고 있게 한다.
    // 그래야 늘리는 대로 따라오는 느낌이 난다. 손가락을 함께 옮기면 그
    // 지점이 따라 움직이므로 이 한 줄이 이동까지 겸한다.
    final Offset raw = d.localFocalPoint - _gestureStartFocusOnPage * next;
    setState(() {
      _scale = next;
      _offset = _clampOffset(raw, pageSize);
    });
  }

  void _onScaleEnd(Size pageSize) {
    if (_drawing) {
      _drawing = false;
      // 손가락이 아직 화면에 둘 이상 있다면 이건 획이 끝난 것이 아니다.
      //
      // 그리는 중에 두 번째 손가락이 닿으면 ScaleGestureRecognizer 가
      // 제스처를 다시 짜면서 onEnd 를 한 번 부르고 곧바로 onStart 를
      // 부른다. 그걸 진짜 끝으로 알고 저장하면, 확대할 때마다 짧은
      // 자국이 악보에 남고 다른 사람에게까지 전송된다.
      if (_pointers >= 2) {
        widget.onStrokeCancel();
      } else {
        widget.onStrokeEnd();
      }
      return;
    }
    setState(() => _offset = _clampOffset(_offset, pageSize));
  }

  void _resetZoom() {
    if (_scale == 1 && _offset == Offset.zero) return;
    setState(() {
      _scale = 1;
      _offset = Offset.zero;
    });
  }

  // ── 그리기 ──────────────────────────────────────────────

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
                ? _page()
                : AspectRatio(aspectRatio: aspect, child: _page()),
          ),
        ),
        // 페이지 넘김은 악보 밖 여백에서도 눌려야 한다. 그래서 악보
        // 사각형이 아니라 화면 전체를 기준으로 둔다.
        if (widget.isPdf) ..._buildPdfControls(),
        // 확대는 PDF 든 이미지든 된다. 배지도 그래야 한다.
        if (_scale > 1.02) _zoomBadge(),
      ],
    );
  }

  /// 지금 확대한 상태라는 것과 되돌리는 방법을 알려준다.
  ///
  /// 두 번 두드리면 된다는 것을 스스로 알아낼 방법이 없다. 눌러도 풀리게
  /// 해서 두 갈래를 다 열어둔다.
  Widget _zoomBadge() {
    return Positioned(
      top: 10,
      right: 10,
      child: GestureDetector(
        onTap: _resetZoom,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.zoom_out_map_rounded,
                  color: Colors.white, size: 13),
              const SizedBox(width: 4),
              Text(
                '${_scale.toStringAsFixed(1)}x',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 악보 한 장과 그 위의 필기. 필기 좌표의 기준이 되는 사각형이다.
  Widget _page() {
    return LayoutBuilder(
      builder: (_, constraints) {
        final Size size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          // 손가락 수를 직접 센다. 제스처 인식기보다 먼저 받는다.
          onPointerDown: (_) => _pointers++,
          onPointerUp: (_) => _pointers = (_pointers - 1).clamp(0, 10),
          onPointerCancel: (_) => _pointers = (_pointers - 1).clamp(0, 10),
          child: GestureDetector(
            // 확대한 악보의 빈 곳에서도 손가락을 받아야 한다.
            behavior: HitTestBehavior.opaque,
            onScaleStart: (d) => _onScaleStart(d, size),
            onScaleUpdate: (d) => _onScaleUpdate(d, size),
            onScaleEnd: (_) => _onScaleEnd(size),
            onDoubleTap: _resetZoom,
            child: ClipRect(
              child: Transform(
                transform: Matrix4.identity()
                  ..translateByDouble(_offset.dx, _offset.dy, 0, 1)
                  ..scaleByDouble(_scale, _scale, 1, 1),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.memory(widget.displayBytes,
                          fit: BoxFit.contain),
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
              ),
            ),
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

    // 굵기를 배율로 나누지 않는다.
    //
    // 한때 나눠 그렸다. 확대해도 선이 굵어지지 않는 편이 자연스럽다고
    // 여겼는데 지우개가 망가졌다. 지우개는 펜 위를 넉넉히 덮어 지운
    // 것인데, 둘 다 페이지 좌표에서 함께 가늘어지면 그 여유도 같이 준다.
    // 지우개가 펜에서 조금 벗어나 지나간 자리는 확대하는 순간 다시
    // 드러났다.
    //
    // 필기는 종이 위에 있는 것이다. 종이를 확대하면 잉크도 함께 커지는
    // 것이 맞다. 그래야 지운 자리가 배율과 상관없이 지워진 채로 남는다.
    final width = stroke.width;
    final paint = Paint()
      ..color = stroke.isEraser
          ? Colors.white
          : stroke.isHighlighter
              ? stroke.color.withValues(alpha: 0.28)
              : stroke.color
      ..strokeWidth = width
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
        width / 2,
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
