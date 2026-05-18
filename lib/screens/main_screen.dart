import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../services/websocket_service.dart';

// ── 필기 데이터 모델 ──────────────────────────────────────────
class Stroke {
  final String id;
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser;

  const Stroke({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
  });
}

// ── 도구 종류 ─────────────────────────────────────────────────
enum DrawTool { pen, eraser, color }

class MainScreen extends StatefulWidget {
  final String nickname;
  final String roomCode;
  final String roomId;

  const MainScreen({
    super.key,
    required this.nickname,
    required this.roomCode,
    required this.roomId,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const _purple = Color(0xFF8B5CF6);

  // ── WebSocket ────────────────────────────────────────────────
  late final WebSocketService _ws;

  // ── 필기 상태 ────────────────────────────────────────────────
  final List<Stroke> _strokes = [];
  Stroke? _currentStroke;
  DrawTool _tool = DrawTool.pen;
  Color _penColor = const Color(0xFF8B5CF6);
  double _penWidth = 3.0;

  // ── 참가자 ──────────────────────────────────────────────────
  final List<Map<String, dynamic>> _participants = [];

  // ── 악보 이미지 ─────────────────────────────────────────────
  Uint8List? _scoreImageBytes;

  // ── 하단 탭 ─────────────────────────────────────────────────
  int _tabIndex = 0;

  // 참가자 아바타 색상
  static const _avatarColors = [
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFF3B82F6),
  ];

  @override
  void initState() {
    super.initState();
    _ws = WebSocketService(
      roomCode: widget.roomCode,
      nickname: widget.nickname,
    );
    _ws.connect();
    _listenWebSocket();

    // 내 자신을 참가자 목록에 추가
    _participants.add({'name': widget.nickname});
  }

  @override
  void dispose() {
    _ws.dispose();
    super.dispose();
  }

  // ── WebSocket 이벤트 처리 ────────────────────────────────────
  void _listenWebSocket() {
    _ws.events.listen((event) {
      switch (event.type) {

        // 입장 시 기존 필기 스냅샷 수신
        case WsEventType.snapshot:
          final strokes = event.data['strokes'] as List<dynamic>? ?? [];
          setState(() {
            _strokes.clear();
            for (final s in strokes) {
              _strokes.add(_strokeFromJson(s as Map<String, dynamic>));
            }
          });
          break;

        // 다른 참가자 필기 수신
        case WsEventType.draw:
          setState(() {
            _strokes.add(_strokeFromJson(event.data));
          });
          break;

        // 지우기
        case WsEventType.erase:
          final id = event.data['stroke_id'] as String?;
          if (id != null) {
            setState(() => _strokes.removeWhere((s) => s.id == id));
          }
          break;

        // 전체 삭제
        case WsEventType.clear:
          setState(() => _strokes.clear());
          break;

        // 참가자 입장
        case WsEventType.userJoined:
          final name = event.data['user_name'] as String?;
          if (name != null && !_participants.any((p) => p['name'] == name)) {
            setState(() => _participants.add({'name': name}));
          }
          break;

        // 참가자 퇴장
        case WsEventType.userLeft:
          final name = event.data['user_name'] as String?;
          if (name != null) {
            setState(() => _participants.removeWhere((p) => p['name'] == name));
          }
          break;

        default:
          break;
      }
    });
  }

  Stroke _strokeFromJson(Map<String, dynamic> json) {
    final pts = (json['points'] as List<dynamic>).map((p) {
      return Offset(
        (p['x'] as num).toDouble(),
        (p['y'] as num).toDouble(),
      );
    }).toList();
    return Stroke(
      id: json['stroke_id'] as String? ?? UniqueKey().toString(),
      points: pts,
      color: Color(int.parse(
          (json['color'] as String? ?? 'FF8B5CF6').replaceFirst('#', ''),
          radix: 16) | 0xFF000000),
      width: (json['width'] as num?)?.toDouble() ?? 3.0,
      isEraser: json['is_eraser'] as bool? ?? false,
    );
  }

  // ── 악보 업로드 바텀시트 ─────────────────────────────────────
  void _showUploadSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 핸들
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD1D5DB),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _SheetItem(
              icon: Icons.camera_alt_outlined,
              label: '사진 촬영',
              onTap: () async {
                Navigator.pop(context);
                final img = await ImagePicker()
                    .pickImage(source: ImageSource.camera);
                if (img != null) {
                  final bytes = await img.readAsBytes();
                  setState(() => _scoreImageBytes = bytes);
                }
              },
            ),
            _SheetItem(
              icon: Icons.image_outlined,
              label: '앨범에서 선택',
              onTap: () async {
                Navigator.pop(context);
                final img = await ImagePicker()
                    .pickImage(source: ImageSource.gallery);
                if (img != null) {
                  final bytes = await img.readAsBytes();
                  setState(() => _scoreImageBytes = bytes);
                }
              },
            ),
            _SheetItem(
              icon: Icons.picture_as_pdf_outlined,
              label: 'PDF 파일 선택',
              onTap: () async {
                Navigator.pop(context);
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['pdf'],
                );
                if (result != null && result.files.first.bytes != null) {
                  setState(() =>
                      _scoreImageBytes = result.files.first.bytes);
                }
              },
            ),
            const Divider(height: 1),
            _SheetItem(
              icon: null,
              label: '취소',
              onTap: () => Navigator.pop(context),
              labelColor: const Color(0xFF6B7280),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── 색상 선택 ────────────────────────────────────────────────
  void _showColorPicker() {
    final colors = [
      const Color(0xFF8B5CF6),
      const Color(0xFFEC4899),
      const Color(0xFF10B981),
      const Color(0xFFF59E0B),
      const Color(0xFF3B82F6),
      const Color(0xFFEF4444),
      Colors.black,
      Colors.white,
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('색상 선택',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: colors.map((c) {
                final selected = c.value == _penColor.value;
                return GestureDetector(
                  onTap: () {
                    setState(() => _penColor = c);
                    Navigator.pop(context);
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? _purple : Colors.grey.shade300,
                        width: selected ? 3 : 1,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  // ── 드로잉 이벤트 ────────────────────────────────────────────
  void _onPanStart(DragStartDetails d, Size canvasSize) {
    final norm = _normalize(d.localPosition, canvasSize);
    final id = '${widget.nickname}_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _currentStroke = Stroke(
        id: id,
        points: [norm],
        color: _tool == DrawTool.eraser ? Colors.white : _penColor,
        width: _tool == DrawTool.eraser ? 20.0 : _penWidth,
        isEraser: _tool == DrawTool.eraser,
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails d, Size canvasSize) {
    if (_currentStroke == null) return;
    final norm = _normalize(d.localPosition, canvasSize);
    setState(() {
      _currentStroke = Stroke(
        id: _currentStroke!.id,
        points: [..._currentStroke!.points, norm],
        color: _currentStroke!.color,
        width: _currentStroke!.width,
        isEraser: _currentStroke!.isEraser,
      );
    });
  }

  void _onPanEnd(Size canvasSize) {
    if (_currentStroke == null) return;
    final stroke = _currentStroke!;
    setState(() {
      _strokes.add(stroke);
      _currentStroke = null;
    });

    // WebSocket으로 전송
    _ws.sendDraw({
      'stroke_id': stroke.id,
      'points': stroke.points
          .map((p) => {'x': p.dx, 'y': p.dy})
          .toList(),
      'color': '#${stroke.color.value.toRadixString(16).padLeft(8, '0').substring(2)}',
      'width': stroke.width,
      'is_eraser': stroke.isEraser,
    });
  }

  Offset _normalize(Offset pos, Size size) {
    return Offset(pos.dx / size.width, pos.dy / size.height);
  }

  // ── 빌드 ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3A3A3A),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            height: MediaQuery.of(context).size.height * 0.95,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                // ── 상단 정보 (방 코드 + 참가자) ──────────────
                _buildHeader(),

                // ── 도구 바 ───────────────────────────────────
                _buildToolBar(),

                // ── 탭 본문 ───────────────────────────────────
                Expanded(child: _buildTabBody()),

                // ── 하단 탭 바 ────────────────────────────────
                _buildBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 상단 헤더 ────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 방 코드
          Row(
            children: [
              const Text('방 코드',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F0FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.roomCode,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _purple,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('방 코드가 복사되었습니다'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                child: const Icon(Icons.copy_rounded,
                    size: 16, color: Color(0xFF9CA3AF)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 참가자
          Row(
            children: [
              Text(
                '참가자 ${_participants.length}명',
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF6B7280)),
              ),
              const SizedBox(width: 8),
              ..._participants.asMap().entries.map((e) {
                final color =
                    _avatarColors[e.key % _avatarColors.length];
                final initial = e.value['name']?.substring(0, 1) ?? '?';
                return Container(
                  margin: const EdgeInsets.only(right: 4),
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      initial,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  // ── 도구 바 ──────────────────────────────────────────────────
  Widget _buildToolBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          // 펜
          _ToolButton(
            icon: Icons.edit_rounded,
            selected: _tool == DrawTool.pen,
            color: _purple,
            onTap: () => setState(() => _tool = DrawTool.pen),
          ),
          const SizedBox(width: 4),
          // 지우개
          _ToolButton(
            icon: Icons.auto_fix_normal_rounded,
            selected: _tool == DrawTool.eraser,
            color: _purple,
            onTap: () => setState(() => _tool = DrawTool.eraser),
          ),
          const SizedBox(width: 4),
          // 색상
          GestureDetector(
            onTap: _showColorPicker,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _penColor,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFE5E7EB), width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 탭 본문 ──────────────────────────────────────────────────
  Widget _buildTabBody() {
    switch (_tabIndex) {
      case 0:
        return _buildScoreTab();
      default:
        return const Center(
          child: Text('준비 중입니다',
              style: TextStyle(color: Color(0xFF9CA3AF))),
        );
    }
  }

  // ── 악보 탭 ──────────────────────────────────────────────────
  Widget _buildScoreTab() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        clipBehavior: Clip.hardEdge,
        child: _scoreImageBytes == null
            ? _buildEmptyScore()
            : _buildCanvas(),
      ),
    );
  }

  // ── 악보 없을 때 ─────────────────────────────────────────────
  Widget _buildEmptyScore() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.upload_rounded,
                size: 32, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 16),
          const Text('악보를 업로드하세요',
              style:
                  TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _showUploadSheet,
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('악보 추가',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ── 악보 + 드로잉 캔버스 ─────────────────────────────────────
  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (_, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, size),
          onPanUpdate: (d) => _onPanUpdate(d, size),
          onPanEnd: (_) => _onPanEnd(size),
          child: Stack(
            children: [
              // 악보 이미지
              Positioned.fill(
                child: Image.memory(
                  _scoreImageBytes!,
                  fit: BoxFit.contain,
                ),
              ),
              // 필기 레이어
              Positioned.fill(
                child: CustomPaint(
                  painter: _DrawingPainter(
                    strokes: _strokes,
                    currentStroke: _currentStroke,
                    canvasSize: size,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── 하단 탭 바 ───────────────────────────────────────────────
  Widget _buildBottomBar() {
    final tabs = [
      {'icon': Icons.music_note_rounded, 'label': '악보'},
      {'icon': Icons.bar_chart_rounded, 'label': '분석'},
      {'icon': Icons.emoji_events_rounded, 'label': '결과'},
    ];
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: tabs.asMap().entries.map((e) {
          final selected = e.key == _tabIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tabIndex = e.key),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      e.value['icon'] as IconData,
                      size: 22,
                      color: selected ? _purple : const Color(0xFF9CA3AF),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      e.value['label'] as String,
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            selected ? _purple : const Color(0xFF9CA3AF),
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── 도구 버튼 ────────────────────────────────────────────────
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 18, color: selected ? color : const Color(0xFF9CA3AF)),
      ),
    );
  }
}

// ── 바텀시트 항목 ─────────────────────────────────────────────
class _SheetItem extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final Color? labelColor;

  const _SheetItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: icon != null
          ? Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: const Color(0xFF6B7280)),
            )
          : null,
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: labelColor ?? const Color(0xFF1A1A2E),
          fontWeight: FontWeight.w500,
        ),
        textAlign: icon == null ? TextAlign.center : TextAlign.start,
      ),
      onTap: onTap,
    );
  }
}

// ── 필기 CustomPainter ────────────────────────────────────────
class _DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final Size canvasSize;

  const _DrawingPainter({
    required this.strokes,
    required this.currentStroke,
    required this.canvasSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in [...strokes, if (currentStroke != null) currentStroke!]) {
      _drawStroke(canvas, size, stroke);
    }
  }

  void _drawStroke(Canvas canvas, Size size, Stroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.isEraser ? Colors.white : stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode =
          stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;

    final path = Path();
    final pts = stroke.points
        .map((p) => Offset(p.dx * size.width, p.dy * size.height))
        .toList();

    if (pts.length == 1) {
      canvas.drawCircle(pts[0], stroke.width / 2, paint..style = PaintingStyle.fill);
      return;
    }

    path.moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter old) => true;
}