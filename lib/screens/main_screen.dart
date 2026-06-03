import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfx/pdfx.dart';
import 'package:image_cropper/image_cropper.dart';
import '../services/websocket_service.dart';
import '../services/api_service.dart';
import '../models/bpm_result.dart';
import 'analysis_tab.dart';
import 'result_tab.dart';

// ── 필기 데이터 모델 ──────────────────────────────────────────
class Stroke {
  final String id;
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser;
  final bool isHighlighter;
  final String? text;

  const Stroke({
    required this.id,
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
    this.isHighlighter = false,
    this.text,
  });
}

enum DrawTool { pen, eraser, highlighter, text }

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

  late final WebSocketService _ws;

  // ── 필기 상태 (PDF 페이지별 분리) ────────────────────────────
  final Map<int, List<Stroke>> _pageStrokes = {};
  List<Stroke> _strokesForPage(int page) {
    _pageStrokes[page] ??= [];
    return _pageStrokes[page]!;
  }
  List<Stroke> get _strokes => _strokesForPage(_currentPdfPage);
  Stroke? _currentStroke;
  DrawTool _tool = DrawTool.pen;
  Color _penColor = const Color(0xFF8B5CF6);
  final double _penWidth = 3.0;

  // ── 참가자 ──────────────────────────────────────────────────
  final List<Map<String, dynamic>> _participants = [];

  // ── 악보 (이미지) ────────────────────────────────────────────
  Uint8List? _scoreImageBytes;

  // ── 악보 (PDF) ───────────────────────────────────────────────
  List<Uint8List> _pdfPages = [];
  int _currentPdfPage = 0;
  bool _isLoadingPdf = false;

  bool get _isPdf => _pdfPages.isNotEmpty;

  Uint8List? get _currentDisplayBytes =>
      _isPdf ? _pdfPages[_currentPdfPage] : _scoreImageBytes;

  // ── 하단 탭 ─────────────────────────────────────────────────
  int _tabIndex = 0;

  // ── 트랙 분리 결과 ───────────────────────────────────────────
  List<TrackResult> _tracks = [];
  String? _audioFilename;
  Uint8List? _audioBytes;

  // ── BPM 분석 결과 ────────────────────────────────────────────
  String? _bpmJobId;
  BpmResult? _bpmResult;
  ResultMode? _preferredResultMode;

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
    _ws = WebSocketService(roomId: widget.roomId, nickname: widget.nickname);
    _participants.add({'name': widget.nickname});

    if (widget.roomId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final fileUrl = await ApiService().getLatestScore(widget.roomId);
          if (mounted && fileUrl != null) await _loadScoreFromUrl(fileUrl);
        } catch (_) {}
        try {
          final strokes = await ApiService().getSnapshot(widget.roomId);
          if (mounted && strokes.isNotEmpty) {
            setState(() {
              for (final s in strokes) _strokes.add(_strokeFromJson(s));
            });
          }
        } catch (_) {}
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ws.connect();
      _listenWebSocket();
    });
  }

  @override
  void dispose() {
    _ws.dispose();
    super.dispose();
  }

  void _listenWebSocket() {
    _ws.events.listen((event) {
      switch (event.type) {
        case WsEventType.syncDraw:
          setState(() => _strokes.add(_strokeFromJson(event.data)));
          break;
        case WsEventType.erase:
          final id = event.data['annotation_id'] as String?;
          if (id != null) setState(() => _strokes.removeWhere((s) => s.id == id));
          break;
        case WsEventType.clear:
          setState(() => _pageStrokes.clear());
          break;
        case WsEventType.userJoined:
          final name = event.data['user_name'] as String?;
          if (name != null && !_participants.any((p) => p['name'] == name)) {
            setState(() => _participants.add({'name': name}));
          }
          break;
        case WsEventType.userLeft:
          final name = event.data['user_name'] as String?;
          if (name != null) setState(() => _participants.removeWhere((p) => p['name'] == name));
          break;
        case WsEventType.userList:
          final users = event.data['users'] as List<dynamic>? ?? [];
          setState(() {
            for (final u in users) {
              final name = u as String?;
              if (name != null && !_participants.any((p) => p['name'] == name)) {
                _participants.add({'name': name});
              }
            }
          });
          break;
        case WsEventType.scoreUploaded:
          final fileUrl = event.data['file_url'] as String?;
          if (fileUrl != null) _loadScoreFromUrl(fileUrl);
          break;
        case WsEventType.trackSeparated:
          final payload = event.data['payload'] as Map<String, dynamic>? ?? {};
          final tracksJson = payload['tracks'] as Map<String, dynamic>? ?? {};
          final results = <TrackResult>[
            if (tracksJson['vocals'] != null)
              TrackResult(label: '보컬', url: tracksJson['vocals'] as String, icon: Icons.music_note_rounded),
            if (tracksJson['drums'] != null)
              TrackResult(label: '드럼', url: tracksJson['drums'] as String, icon: Icons.graphic_eq_rounded),
            if (tracksJson['bass'] != null)
              TrackResult(label: '베이스', url: tracksJson['bass'] as String, icon: Icons.bar_chart_rounded),
            if (tracksJson['other'] != null)
              TrackResult(label: '기타', url: tracksJson['other'] as String, icon: Icons.queue_music_rounded),
          ];
          if (mounted) setState(() => _tracks = results);
          break;
        case WsEventType.bpmAnalyzed:
          final jobId = event.data['job_id'] as String?;
          if (jobId != null && mounted) {
            setState(() => _bpmJobId = jobId);
            _loadBpmResult(jobId);
          }
          break;
        default:
          break;
      }
    });
  }

  // ── BPM 결과 로드 ────────────────────────────────────────────
  Future<void> _loadBpmResult(String jobId) async {
    try {
      final data = await ApiService().getBpmResult(jobId);
      if (mounted) setState(() => _bpmResult = BpmResult.fromJson(data));
    } catch (_) {}
  }

  // ── 악보 URL 다운로드 및 표시 ──────────────────────────────────
  Future<void> _loadScoreFromUrl(String fileUrl) async {
    try {
      final bytes = await ApiService().downloadScore(fileUrl);
      if (!mounted) return;
      if (fileUrl.toLowerCase().endsWith('.pdf')) {
        await _loadPdfPages(bytes);
      } else {
        setState(() {
          _scoreImageBytes = bytes;
          _pdfPages = [];
          _currentPdfPage = 0;
          _pageStrokes.clear();
        });
      }
    } catch (_) {}
  }

  // ── PDF 페이지 렌더링 ─────────────────────────────────────────
  Future<void> _loadPdfPages(Uint8List bytes) async {
    if (!mounted) return;
    setState(() => _isLoadingPdf = true);
    try {
      final document = await PdfDocument.openData(bytes);
      final pages = <Uint8List>[];
      for (int i = 1; i <= document.pagesCount; i++) {
        final page = await document.getPage(i);
        final pageImage = await page.render(
          width: page.width * 2,
          height: page.height * 2,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#ffffff',
        );
        if (pageImage != null) pages.add(pageImage.bytes);
        await page.close();
      }
      await document.close();
      if (mounted) {
        setState(() {
          _pdfPages = pages;
          _currentPdfPage = 0;
          _scoreImageBytes = null;
          _isLoadingPdf = false;
          _pageStrokes.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingPdf = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 로드 실패: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  // ── 이미지 크롭 ──────────────────────────────────────────────
  Future<Uint8List?> _cropImage(String imagePath) async {
    final croppedFile = await ImageCropper().cropImage(
      sourcePath: imagePath,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '영역 선택',
          toolbarColor: _purple,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
          hideBottomControls: false,
        ),
      ],
    );
    if (croppedFile == null) return null;
    return await croppedFile.readAsBytes();
  }

  Future<void> _uploadScore(Uint8List bytes, String filename) async {
    try {
      final fileUrl = await ApiService().uploadScore(widget.roomId, bytes, filename);
      _ws.sendScoreUploaded(fileUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e')),
        );
      }
    }
  }

  Stroke _strokeFromJson(Map<String, dynamic> json) {
    final p = json['payload'] as Map<String, dynamic>? ?? json;
    final toolType = p['tool_type'] as String? ?? 'pen';
    final isEraser = toolType == 'eraser';
    final isHighlighter = toolType == 'highlighter';
    final isText = toolType == 'text';
    final text = p['text'] as String?;
    final pts = (p['stroke_data'] as List<dynamic>).map((pt) {
      return Offset((pt['x'] as num).toDouble(), (pt['y'] as num).toDouble());
    }).toList();
    return Stroke(
      id: p['annotation_id'] as String? ?? UniqueKey().toString(),
      points: pts,
      color: Color(int.parse(
          (p['color'] as String? ?? '#8B5CF6').replaceFirst('#', ''), radix: 16) | 0xFF000000),
      width: isEraser ? 20.0 : isHighlighter ? 18.0 : isText ? 14.0 : 3.0,
      isEraser: isEraser,
      isHighlighter: isHighlighter,
      text: text,
    );
  }

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
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40, height: 4,
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
                final img = await ImagePicker().pickImage(source: ImageSource.camera);
                if (img != null) {
                  final croppedBytes = await _cropImage(img.path);
                  if (croppedBytes != null && mounted) {
                    setState(() {
                      _scoreImageBytes = croppedBytes;
                      _pdfPages = [];
                      _pageStrokes.clear();
                    });
                    await _uploadScore(croppedBytes, img.name);
                  }
                }
              },
            ),
            _SheetItem(
              icon: Icons.image_outlined,
              label: '앨범에서 선택',
              onTap: () async {
                Navigator.pop(context);
                final img = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (img != null) {
                  final croppedBytes = await _cropImage(img.path);
                  if (croppedBytes != null && mounted) {
                    setState(() {
                      _scoreImageBytes = croppedBytes;
                      _pdfPages = [];
                      _pageStrokes.clear();
                    });
                    await _uploadScore(croppedBytes, img.name);
                  }
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
                  withData: true,
                );
                if (result != null && result.files.first.bytes != null) {
                  final bytes = result.files.first.bytes!;
                  final filename = result.files.first.name;
                  await _uploadScore(bytes, filename);
                  await _loadPdfPages(bytes);
                }
              },
            ),
            const Divider(height: 1),
            _SheetItem(
              icon: null, label: '취소',
              onTap: () => Navigator.pop(context),
              labelColor: const Color(0xFF6B7280),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showColorPicker() {
    final colors = [
      const Color(0xFF8B5CF6), const Color(0xFFEC4899),
      const Color(0xFF10B981), const Color(0xFFF59E0B),
      const Color(0xFF3B82F6), const Color(0xFFEF4444),
      Colors.black, Colors.white,
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
            const Text('색상 선택', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12, runSpacing: 12,
              children: colors.map((c) {
                final selected = c.value == _penColor.value;
                return GestureDetector(
                  onTap: () { setState(() => _penColor = c); Navigator.pop(context); },
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: c, shape: BoxShape.circle,
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

  void _onPanStart(DragStartDetails d, Size canvasSize) {
    if (_tool == DrawTool.text) return;
    final norm = _normalize(d.localPosition, canvasSize);
    final id = '${widget.nickname}_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _currentStroke = Stroke(
        id: id, points: [norm],
        color: _tool == DrawTool.eraser ? Colors.white : _penColor,
        width: _tool == DrawTool.eraser ? 20.0 : _tool == DrawTool.highlighter ? 18.0 : _penWidth,
        isEraser: _tool == DrawTool.eraser,
        isHighlighter: _tool == DrawTool.highlighter,
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
        isHighlighter: _currentStroke!.isHighlighter,
      );
    });
  }

  void _onPanEnd(Size canvasSize) {
    if (_currentStroke == null) return;
    final stroke = _currentStroke!;
    setState(() { _strokes.add(stroke); _currentStroke = null; });
    final toolType = stroke.isEraser ? 'eraser' : stroke.isHighlighter ? 'highlighter' : stroke.text != null ? 'text' : 'pen';
    _ws.sendDraw({
      'annotation_id': stroke.id,
      'member_id': widget.nickname,
      'tool_type': toolType,
      'color': '#${stroke.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'stroke_data': stroke.points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      if (stroke.text != null) 'text': stroke.text,
      'is_deleted': false,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Offset _normalize(Offset pos, Size size) =>
      Offset(pos.dx / size.width, pos.dy / size.height);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3A3A3A),
      resizeToAvoidBottomInset: false,
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
                _buildHeader(),
                if (_tabIndex == 0) _buildToolBar(),
                Expanded(child: _buildTabBody()),
                _buildBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('방 코드', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F0FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(widget.roomCode,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold,
                        color: _purple, letterSpacing: 1.5)),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: widget.roomCode));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('방 코드가 복사되었습니다'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  }
                },
                child: const Icon(Icons.copy_rounded, size: 16, color: Color(0xFF9CA3AF)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('참가자 ${_participants.length}명',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(width: 8),
              ..._participants.asMap().entries.map((e) {
                final color = _avatarColors[e.key % _avatarColors.length];
                final initial = e.value['name']?.substring(0, 1) ?? '?';
                return Container(
                  margin: const EdgeInsets.only(right: 4),
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Center(
                    child: Text(initial,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

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
          _ToolButton(
            icon: Icons.edit_rounded,
            selected: _tool == DrawTool.pen,
            color: _purple,
            onTap: () => setState(() => _tool = DrawTool.pen),
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.highlight_rounded,
            selected: _tool == DrawTool.highlighter,
            color: const Color(0xFFF59E0B),
            onTap: () => setState(() => _tool = DrawTool.highlighter),
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.auto_fix_normal_rounded,
            selected: _tool == DrawTool.eraser,
            color: _purple,
            onTap: () => setState(() => _tool = DrawTool.eraser),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _showColorPicker,
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: _penColor, shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFE5E7EB), width: 2),
              ),
            ),
          ),
          const Spacer(),
          _ToolButton(
            icon: Icons.upload_rounded,
            selected: false,
            color: _purple,
            onTap: _showUploadSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody() {
    return IndexedStack(
      index: _tabIndex,
      children: [
        _buildScoreTab(),
        AnalysisTab(
          roomId: widget.roomId,
          roomCode: widget.roomCode,
          ws: _ws,
          onGoToResult: () => setState(() {
            _preferredResultMode = ResultMode.bpm;
            _tabIndex = 2;
          }),
          onGoToTrackResult: () => setState(() {
            _preferredResultMode = ResultMode.track;
            _tabIndex = 2;
          }),
          onBpmJobId: (jobId) {
            setState(() => _bpmJobId = jobId);
            _loadBpmResult(jobId);
          },
          onAudioPicked: (bytes, filename) => setState(() {
            _audioBytes = bytes;
            _audioFilename = filename;
          }),
        ),
        ResultTab(
          tracks: _tracks,
          audioFilename: _audioFilename,
          audioBytes: _audioBytes,
          bpmJobId: _bpmJobId,
          bpmResult: _bpmResult,
          preferredMode: _preferredResultMode,
        ),
      ],
    );
  }

  Widget _buildScoreTab() {
    if (_isLoadingPdf) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: _purple),
                SizedBox(height: 12),
                Text('PDF 로딩 중...', style: TextStyle(color: Color(0xFF6B7280), fontSize: 13)),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        clipBehavior: Clip.hardEdge,
        child: _currentDisplayBytes == null ? _buildEmptyScore() : _buildCanvas(),
      ),
    );
  }

  Widget _buildEmptyScore() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64, height: 64,
            decoration: const BoxDecoration(color: Color(0xFFF3F4F6), shape: BoxShape.circle),
            child: const Icon(Icons.upload_rounded, size: 32, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 16),
          const Text('악보를 업로드하세요',
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _showUploadSheet,
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('악보 추가', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    final displayBytes = _currentDisplayBytes!;

    return LayoutBuilder(
      builder: (_, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, size),
          onPanUpdate: (d) => _onPanUpdate(d, size),
          onPanEnd: (_) => _onPanEnd(size),
          child: Stack(
            children: [
              Positioned.fill(child: Image.memory(displayBytes, fit: BoxFit.contain)),
              Positioned.fill(
                child: CustomPaint(
                  painter: _DrawingPainter(
                    strokes: _strokes,
                    currentStroke: _currentStroke,
                    canvasSize: size,
                  ),
                ),
              ),

              // ── PDF 페이지 이동 (좌/우 탭존) ─────────────────────
              if (_isPdf) ...[
                // 이전 페이지 (왼쪽)
                Positioned(
                  left: 0, top: 0, bottom: 0, width: 56,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _currentPdfPage > 0
                        ? () => setState(() => _currentPdfPage--)
                        : null,
                    child: _currentPdfPage > 0
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(left: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.35),
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(6),
                              child: const Icon(Icons.chevron_left, color: Colors.white, size: 22),
                            ),
                          )
                        : null,
                  ),
                ),
                // 다음 페이지 (오른쪽)
                Positioned(
                  right: 0, top: 0, bottom: 0, width: 56,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _currentPdfPage < _pdfPages.length - 1
                        ? () => setState(() => _currentPdfPage++)
                        : null,
                    child: _currentPdfPage < _pdfPages.length - 1
                        ? Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.35),
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(6),
                              child: const Icon(Icons.chevron_right, color: Colors.white, size: 22),
                            ),
                          )
                        : null,
                  ),
                ),
                // 페이지 카운터
                Positioned(
                  bottom: 10, left: 0, right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_currentPdfPage + 1} / ${_pdfPages.length}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),         // Stack
        );           // GestureDetector
      },
    );
  }

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
                    Icon(e.value['icon'] as IconData, size: 22,
                        color: selected ? _purple : const Color(0xFF9CA3AF)),
                    const SizedBox(height: 2),
                    Text(e.value['label'] as String,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected ? _purple : const Color(0xFF9CA3AF),
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        )),
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

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  const _ToolButton({required this.icon, required this.selected, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: selected ? color : const Color(0xFF9CA3AF)),
      ),
    );
  }
}

class _SheetItem extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onTap;
  final Color? labelColor;

  const _SheetItem({required this.icon, required this.label, required this.onTap, this.labelColor});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: icon != null
          ? Container(
              width: 40, height: 40,
              decoration: const BoxDecoration(color: Color(0xFFF3F4F6), shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: const Color(0xFF6B7280)),
            )
          : null,
      title: Text(label,
          style: TextStyle(
            fontSize: 15,
            color: labelColor ?? const Color(0xFF1A1A2E),
            fontWeight: FontWeight.w500,
          ),
          textAlign: icon == null ? TextAlign.center : TextAlign.start),
      onTap: onTap,
    );
  }
}

class _DrawingPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? currentStroke;
  final Size canvasSize;

  const _DrawingPainter({required this.strokes, required this.currentStroke, required this.canvasSize});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (final stroke in [...strokes, if (currentStroke != null) currentStroke!]) {
      _drawStroke(canvas, size, stroke);
    }
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, Size size, Stroke stroke) {
    if (stroke.points.isEmpty) return;

    // 텍스트 어노테이션
    if (stroke.text != null) {
      final pos = Offset(
        stroke.points.first.dx * size.width,
        stroke.points.first.dy * size.height,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: stroke.text,
          style: TextStyle(
            color: stroke.color,
            fontSize: stroke.width,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - pos.dx);
      canvas.drawRect(
        Rect.fromLTWH(pos.dx - 3, pos.dy - 2, tp.width + 6, tp.height + 4),
        Paint()..color = stroke.color.withValues(alpha: 0.12),
      );
      tp.paint(canvas, pos);
      return;
    }

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

    final pts = stroke.points.map((p) => Offset(p.dx * size.width, p.dy * size.height)).toList();
    if (pts.length == 1) {
      canvas.drawCircle(pts[0], stroke.width / 2, paint..style = PaintingStyle.fill);
      return;
    }
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 1; i < pts.length; i++) path.lineTo(pts[i].dx, pts[i].dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter old) => true;
}
