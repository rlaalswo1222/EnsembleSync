import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';

import '../models/bpm_result.dart';
import '../models/stroke.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../widgets/room_header.dart';
import '../widgets/score_canvas.dart';
import 'analysis_tab.dart';
import 'result_tab.dart';

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
  static const _shareChannel = MethodChannel('ensemble_sync/share');

  late final WebSocketService _ws;

  final Map<int, List<Stroke>> _pageStrokes = {};
  Stroke? _currentStroke;
  DrawTool _tool = DrawTool.pen;
  Color _penColor = _purple;
  final double _penWidth = 3.0;

  final List<Map<String, dynamic>> _participants = [];

  Uint8List? _scoreImageBytes;
  PdfDocument? _pdfDocument;
  int _pdfPageCount = 0;
  final Map<int, Uint8List> _pdfPageCache = {};
  final Set<int> _loadingPdfPages = {};
  int _currentPdfPage = 0;
  bool _isLoadingPdf = false;

  int _tabIndex = 0;

  List<TrackResult> _tracks = [];
  String? _audioFilename;
  Uint8List? _audioBytes;

  String? _bpmJobId;
  BpmResult? _bpmResult;
  ResultMode? _preferredResultMode;

  bool get _isPdf => _pdfDocument != null && _pdfPageCount > 0;
  Uint8List? get _currentDisplayBytes =>
      _isPdf ? _pdfPageCache[_currentPdfPage] : _scoreImageBytes;

  List<Stroke> _strokesForPage(int page) {
    _pageStrokes[page] ??= [];
    return _pageStrokes[page]!;
  }

  List<Stroke> get _strokes => _strokesForPage(_currentPdfPage);

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
              for (final stroke in strokes) {
                _addStrokeFromPayload(stroke);
              }
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
    unawaited(_pdfDocument?.close() ?? Future<void>.value());
    _ws.dispose();
    super.dispose();
  }

  void _listenWebSocket() {
    _ws.events.listen((event) {
      switch (event.type) {
        case WsEventType.syncDraw:
          setState(() => _addStrokeFromPayload(event.data));
          break;
        case WsEventType.erase:
          final id = event.data['annotation_id'] as String?;
          if (id != null) {
            setState(() {
              for (final strokes in _pageStrokes.values) {
                strokes.removeWhere((s) => s.id == id);
              }
            });
          }
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
          if (name != null) {
            setState(() => _participants.removeWhere((p) => p['name'] == name));
          }
          break;
        case WsEventType.userList:
          final users = event.data['users'] as List<dynamic>? ?? [];
          setState(() {
            for (final u in users) {
              final name = u as String?;
              if (name != null &&
                  !_participants.any((p) => p['name'] == name)) {
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
              TrackResult(
                label: '보컬',
                url: tracksJson['vocals'] as String,
                icon: Icons.music_note_rounded,
              ),
            if (tracksJson['drums'] != null)
              TrackResult(
                label: '드럼',
                url: tracksJson['drums'] as String,
                icon: Icons.graphic_eq_rounded,
              ),
            if (tracksJson['bass'] != null)
              TrackResult(
                label: '베이스',
                url: tracksJson['bass'] as String,
                icon: Icons.bar_chart_rounded,
              ),
            if (tracksJson['other'] != null)
              TrackResult(
                label: '기타',
                url: tracksJson['other'] as String,
                icon: Icons.queue_music_rounded,
              ),
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

  Future<void> _loadBpmResult(String jobId) async {
    try {
      final data = await ApiService().getBpmResult(jobId);
      if (mounted) setState(() => _bpmResult = BpmResult.fromJson(data));
    } catch (e) {
      if (mounted) _showSnack('BPM 결과 조회 실패: $e');
    }
  }

  Future<void> _loadScoreFromUrl(String fileUrl) async {
    try {
      final bytes = await ApiService().downloadScore(fileUrl);
      if (!mounted) return;
      if (fileUrl.toLowerCase().endsWith('.pdf')) {
        await _loadPdfPages(bytes);
      } else {
        await _showImageScore(bytes);
      }
    } catch (e) {
      if (mounted) _showSnack('악보 다운로드 실패: $e');
    }
  }

  Future<void> _loadPdfPages(Uint8List bytes) async {
    setState(() => _isLoadingPdf = true);
    PdfDocument? nextDocument;
    try {
      nextDocument = await PdfDocument.openData(bytes);
      final firstPageBytes = await _renderPdfPageBytes(nextDocument, 0);
      if (firstPageBytes == null) {
        throw Exception('첫 페이지 렌더링 실패');
      }

      if (!mounted) {
        unawaited(nextDocument.close());
        nextDocument = null;
        return;
      }

      final previousDocument = _pdfDocument;
      setState(() {
        _pdfDocument = nextDocument;
        _pdfPageCount = nextDocument!.pagesCount;
        _pdfPageCache
          ..clear()
          ..[0] = firstPageBytes;
        _loadingPdfPages.clear();
        _currentPdfPage = 0;
        _scoreImageBytes = null;
        _pageStrokes.clear();
        _isLoadingPdf = false;
      });
      nextDocument = null;
      unawaited(previousDocument?.close() ?? Future<void>.value());
      _prefetchPdfNeighbors(0);
    } catch (e) {
      unawaited(nextDocument?.close() ?? Future<void>.value());
      if (mounted) {
        setState(() => _isLoadingPdf = false);
        _showSnack('PDF 로드 실패: $e');
      }
    }
  }

  Future<void> _showImageScore(Uint8List bytes) async {
    final previousDocument = _pdfDocument;
    if (!mounted) return;
    setState(() {
      _scoreImageBytes = bytes;
      _pdfDocument = null;
      _pdfPageCount = 0;
      _pdfPageCache.clear();
      _loadingPdfPages.clear();
      _currentPdfPage = 0;
      _pageStrokes.clear();
      _isLoadingPdf = false;
    });
    unawaited(previousDocument?.close() ?? Future<void>.value());
  }

  Future<Uint8List?> _renderPdfPageBytes(
    PdfDocument document,
    int pageIndex,
  ) async {
    final page = await document.getPage(pageIndex + 1);
    try {
      final image = await page.render(
        width: page.width * 2,
        height: page.height * 2,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#ffffff',
      );
      return image?.bytes;
    } finally {
      await page.close();
    }
  }

  Future<void> _ensurePdfPageRendered(int pageIndex) async {
    final document = _pdfDocument;
    if (document == null ||
        pageIndex < 0 ||
        pageIndex >= _pdfPageCount ||
        _pdfPageCache.containsKey(pageIndex) ||
        _loadingPdfPages.contains(pageIndex)) {
      return;
    }

    if (!mounted) return;
    setState(() => _loadingPdfPages.add(pageIndex));
    try {
      final bytes = await _renderPdfPageBytes(document, pageIndex);
      if (!mounted || document != _pdfDocument) return;
      if (bytes != null) {
        setState(() => _pdfPageCache[pageIndex] = bytes);
      }
    } catch (e) {
      if (mounted && pageIndex == _currentPdfPage) {
        _showSnack('PDF 페이지 로드 실패: $e');
      }
    } finally {
      if (mounted && document == _pdfDocument) {
        setState(() => _loadingPdfPages.remove(pageIndex));
      }
    }
  }

  void _prefetchPdfNeighbors(int pageIndex) {
    unawaited(_ensurePdfPageRendered(pageIndex - 1));
    unawaited(_ensurePdfPageRendered(pageIndex + 1));
  }

  Future<void> _goToPdfPage(int pageIndex) async {
    if (pageIndex < 0 || pageIndex >= _pdfPageCount) return;
    setState(() => _currentPdfPage = pageIndex);
    await _ensurePdfPageRendered(pageIndex);
    _prefetchPdfNeighbors(pageIndex);
  }

  Future<void> _uploadScore(Uint8List bytes, String filename) async {
    try {
      final fileUrl =
          await ApiService().uploadScore(widget.roomId, bytes, filename);
      _ws.sendScoreUploaded(fileUrl);
    } catch (e) {
      if (mounted) _showSnack('업로드 실패: $e');
    }
  }

  Future<Uint8List?> _cropImage(String path) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '영역 선택',
          toolbarColor: _purple,
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
      ],
    );
    if (cropped == null) return null;
    return cropped.readAsBytes();
  }

  void _addStrokeFromPayload(Map<String, dynamic> json) {
    final payload = json['payload'] as Map<String, dynamic>? ?? json;
    final page = (payload['page_index'] as num?)?.toInt() ?? 0;
    _strokesForPage(page).add(_strokeFromPayload(payload));
  }

  Stroke _strokeFromPayload(Map<String, dynamic> payload) {
    final toolType = payload['tool_type'] as String? ?? 'pen';
    final isEraser = toolType == 'eraser';
    final isHighlighter = toolType == 'highlighter';
    final pts = (payload['stroke_data'] as List<dynamic>).map((pt) {
      return Offset((pt['x'] as num).toDouble(), (pt['y'] as num).toDouble());
    }).toList();
    return Stroke(
      id: payload['annotation_id'] as String? ?? UniqueKey().toString(),
      points: pts,
      color: Color(
        int.parse(
              (payload['color'] as String? ?? '#8B5CF6').replaceFirst('#', ''),
              radix: 16,
            ) |
            0xFF000000,
      ),
      width: isEraser
          ? 20.0
          : isHighlighter
              ? 18.0
              : _penWidth,
      isEraser: isEraser,
      isHighlighter: isHighlighter,
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
                final img =
                    await ImagePicker().pickImage(source: ImageSource.camera);
                if (img == null) return;
                final bytes = await _cropImage(img.path);
                if (bytes == null) return;
                if (mounted) await _showImageScore(bytes);
                await _uploadScore(bytes, img.name);
              },
            ),
            _SheetItem(
              icon: Icons.image_outlined,
              label: '앨범에서 선택',
              onTap: () async {
                Navigator.pop(context);
                final img =
                    await ImagePicker().pickImage(source: ImageSource.gallery);
                if (img == null) return;
                final bytes = await _cropImage(img.path);
                if (bytes == null) return;
                if (mounted) await _showImageScore(bytes);
                await _uploadScore(bytes, img.name);
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
                if (result == null || result.files.first.bytes == null) return;
                final bytes = result.files.first.bytes!;
                final filename = result.files.first.name;
                await _loadPdfPages(bytes);
                await _uploadScore(bytes, filename);
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

  void _showColorPicker() {
    final colors = [
      _purple,
      const Color(0xFFEC4899),
      const Color(0xFF10B981),
      const Color(0xFFF59E0B),
      const Color(0xFF3B82F6),
      const Color(0xFFEF4444),
      Colors.black,
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: colors.map((color) {
            final selected = color.toARGB32() == _penColor.toARGB32();
            return GestureDetector(
              onTap: () {
                setState(() => _penColor = color);
                Navigator.pop(context);
              },
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color,
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
      ),
    );
  }

  void _onPanStart(DragStartDetails d, Size canvasSize) {
    final norm = _normalize(d.localPosition, canvasSize);
    final id = '${widget.nickname}_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _currentStroke = Stroke(
        id: id,
        points: [norm],
        color: _tool == DrawTool.eraser ? Colors.white : _penColor,
        width: _tool == DrawTool.eraser
            ? 20.0
            : _tool == DrawTool.highlighter
                ? 18.0
                : _penWidth,
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
    setState(() {
      _strokes.add(stroke);
      _currentStroke = null;
    });
    final toolType = stroke.isEraser
        ? 'eraser'
        : stroke.isHighlighter
            ? 'highlighter'
            : 'pen';
    _ws.sendDraw({
      'annotation_id': stroke.id,
      'member_id': widget.nickname,
      'page_index': _currentPdfPage,
      'tool_type': toolType,
      'color':
          '#${stroke.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'stroke_data': stroke.points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'is_deleted': false,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Offset _normalize(Offset pos, Size size) =>
      Offset(pos.dx / size.width, pos.dy / size.height);

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String get _roomShareText =>
      'EnsembleSync 방 코드: ${widget.roomCode}\n앱에서 방 참가를 눌러 이 코드를 입력해주세요.';

  Future<void> _copyRoomCode() async {
    await Clipboard.setData(ClipboardData(text: widget.roomCode));
    if (mounted) _showSnack('방 코드가 복사되었습니다.');
  }

  Future<void> _shareRoomCodeToKakao() async {
    try {
      final shared = await _shareChannel.invokeMethod<bool>(
        'shareToKakao',
        {'text': _roomShareText},
      );
      if (mounted && shared != true) {
        _showSnack('카카오톡이 설치되어 있지 않습니다.');
      }
    } on PlatformException catch (e) {
      if (mounted) {
        _showSnack('카카오톡 공유 실패: ${e.message ?? e.code}');
      }
    }
  }

  void _showRoomShareSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _SheetItem(
              icon: Icons.copy_rounded,
              label: '클립보드 복사',
              onTap: () {
                Navigator.pop(context);
                _copyRoomCode();
              },
            ),
            _SheetItem(
              icon: Icons.chat_bubble_outline_rounded,
              label: '카카오톡으로 공유',
              onTap: () {
                Navigator.pop(context);
                _shareRoomCodeToKakao();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

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
    return RoomHeader(
      roomCode: widget.roomCode,
      participantNames: _participants
          .map((participant) => participant['name'] as String? ?? '?')
          .toList(),
      onShareRoom: _showRoomShareSheet,
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
          const SizedBox(width: 8),
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
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        clipBehavior: Clip.hardEdge,
        child: _isLoadingPdf || (_isPdf && _currentDisplayBytes == null)
            ? const Center(child: CircularProgressIndicator(color: _purple))
            : _currentDisplayBytes == null
                ? _buildEmptyScore()
                : _buildCanvas(),
      ),
    );
  }

  Widget _buildEmptyScore() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: Color(0xFFF3F4F6),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.upload_rounded,
                size: 32, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 16),
          const Text('악보를 업로드하세요',
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _showUploadSheet,
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('악보 추가',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    final displayBytes = _currentDisplayBytes!;
    return ScoreCanvas(
      displayBytes: displayBytes,
      isPdf: _isPdf,
      currentPdfPage: _currentPdfPage,
      pdfPageCount: _pdfPageCount,
      strokes: _strokes,
      currentStroke: _currentStroke,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onPdfPageChanged: _goToPdfPage,
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
        children: tabs.asMap().entries.map((entry) {
          final selected = entry.key == _tabIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tabIndex = entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      entry.value['icon'] as IconData,
                      size: 22,
                      color: selected ? _purple : const Color(0xFF9CA3AF),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.value['label'] as String,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected ? _purple : const Color(0xFF9CA3AF),
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
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
          color: selected ? color.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 18, color: selected ? color : const Color(0xFF9CA3AF)),
      ),
    );
  }
}

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
              decoration: const BoxDecoration(
                color: Color(0xFFF3F4F6),
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
