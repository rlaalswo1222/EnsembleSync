import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../models/bpm_result.dart';
import '../models/stroke.dart';
import '../models/track_result.dart';
import '../services/api_service.dart';
import '../services/platform_share.dart';
import '../services/score_pdf_document.dart';
import '../services/score_pdf_renderer.dart';
import '../services/websocket_service.dart';
import '../widgets/room_header.dart';
import '../widgets/score_canvas.dart';
import 'analysis_tab.dart';
import 'result_tab.dart';
import '../theme/tokens.dart';

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

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const _primary = AppColors.ink;

  late final WebSocketService _ws;

  final Map<int, List<Stroke>> _pageStrokes = {};
  Stroke? _currentStroke;
  DrawTool _tool = DrawTool.pen;
  Color _penColor = _primary;
  final double _penWidth = 3.0;

  final List<Map<String, dynamic>> _participants = [];

  Uint8List? _scoreImageBytes;
  ScorePdfDocument? _pdfDocument;
  int _pdfPageCount = 0;
  final Map<int, Uint8List> _pdfPageCache = {};
  final Set<int> _loadingPdfPages = {};
  int _currentPdfPage = 0;
  bool _isLoadingPdf = false;
  String? _loadingScoreUrl;
  String? _loadedScoreUrl;

  int _tabIndex = 0;

  /// 스템 이름 → (화면 이름, 아이콘). 순서가 곧 화면에 쌓이는 순서다.
  ///
  /// 'other' 를 '기타'로 부르던 때가 있었는데, 6트랙 모델부터는 진짜 기타가
  /// 따로 나온다. 겹치지 않게 '나머지'로 바꿨다.
  static const Map<String, (String, IconData)> _stemLabels =
      <String, (String, IconData)>{
    'vocals': ('보컬', Icons.mic_rounded),
    'drums': ('드럼', Icons.graphic_eq_rounded),
    'bass': ('베이스', Icons.bar_chart_rounded),
    'guitar': ('기타', Icons.music_note_rounded),
    'piano': ('피아노', Icons.piano_rounded),
    'other': ('나머지', Icons.queue_music_rounded),
  };

  List<TrackResult> _tracks = [];
  String? _analysisUrl;
  String? _audioFilename;
  Uint8List? _audioBytes;
  // 업로드된 음원 주소. 웹에서는 바이트 재생이 불가해 이 주소로 재생한다.
  String? _audioUrl;

  String? _bpmJobId;
  BpmResult? _bpmResult;
  ResultMode? _preferredResultMode;

  /// 분리는 끝났고 BPM 분석만 아직 도는 중. 결과 화면에서 진행 표시를 낸다.
  bool _bpmPending = false;

  /// 정리까지 며칠 남았는지. 임박했을 때만 띠를 띄운다.
  ///
  /// 30일 내내 경고를 붙여두면 아무도 안 읽는다. 서버가 warn 을 계산해
  /// 주므로 앱은 그 값만 보고 띄울지 정한다.
  int? _daysLeft;
  double _roomMb = 0;
  bool _showExpiryBanner = false;
  bool _keeping = false;

  bool get _isPdf => _pdfDocument != null && _pdfPageCount > 0;
  Uint8List? get _currentDisplayBytes =>
      _isPdf ? _pdfPageCache[_currentPdfPage] : _scoreImageBytes;

  List<Stroke> _strokesForPage(int page) {
    _pageStrokes[page] ??= [];
    return _pageStrokes[page]!;
  }

  List<Stroke> get _strokes => _strokesForPage(_currentPdfPage);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 화면이 꺼져 있는 동안 연결이 끊기곤 한다. 돌아오면 확인해서 다시 붙는다.
    if (state == AppLifecycleState.resumed) {
      _ws.ensureConnected();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _loadRoomStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        case WsEventType.audioUploaded:
          final payload = event.data['payload'] as Map<String, dynamic>? ?? {};
          final eventRoomId = payload['room_id'] as String?;
          if (eventRoomId != null && eventRoomId != widget.roomId) break;
          final filename = payload['filename'] as String?;
          if (filename != null && mounted) {
            setState(() {
              if (_audioFilename != filename) {
                _audioBytes = null;
              }
              _audioFilename = filename;
              _audioUrl = payload['file_url'] as String?;
            });
          }
          break;
        case WsEventType.trackSeparated:
          applySeparationPayload(
            event.data['payload'] as Map<String, dynamic>? ?? {},
          );
          break;
        case WsEventType.bpmAnalyzed:
          final jobId = event.data['job_id'] as String?;
          if (jobId != null && mounted) {
            setState(() {
              _bpmJobId = jobId;
              _bpmPending = false;
              // 화면은 그대로 둔다. 분리 결과 화면의 BPM 칸이 채워질 뿐이다.
              if (_tracks.isEmpty) _preferredResultMode = ResultMode.bpm;
            });
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
    if (_loadingScoreUrl == fileUrl || _loadedScoreUrl == fileUrl) return;
    _loadingScoreUrl = fileUrl;
    try {
      final bytes = await ApiService().downloadScore(fileUrl);
      if (!mounted) return;
      if (fileUrl.toLowerCase().endsWith('.pdf')) {
        final loaded = await _loadPdfPages(bytes);
        if (!loaded) return;
      } else {
        await _showImageScore(bytes);
      }
      _loadedScoreUrl = fileUrl;
    } catch (e) {
      debugPrint('Score download failed: $e');
      if (mounted) _showSnack('악보를 불러오지 못했습니다. 잠시 후 다시 시도해주세요.');
    } finally {
      if (_loadingScoreUrl == fileUrl) _loadingScoreUrl = null;
    }
  }

  Future<bool> _loadPdfPages(Uint8List bytes) async {
    setState(() => _isLoadingPdf = true);
    ScorePdfDocument? nextDocument;
    try {
      if (!_hasPdfHeader(bytes)) {
        throw const FormatException('Response is not a PDF file');
      }
      nextDocument = await openScorePdf(bytes);
      final firstPageBytes = await _renderPdfPageBytes(nextDocument, 0);
      if (firstPageBytes == null) {
        throw Exception('첫 페이지 렌더링 실패');
      }

      if (!mounted) {
        unawaited(nextDocument.close());
        nextDocument = null;
        return false;
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
      return true;
    } catch (e) {
      unawaited(nextDocument?.close() ?? Future<void>.value());
      debugPrint('PDF load failed: $e');
      if (mounted) {
        setState(() => _isLoadingPdf = false);
        _showSnack('이 PDF를 열 수 없습니다. 파일을 확인한 뒤 다시 업로드해주세요.');
      }
      return false;
    }
  }

  bool _hasPdfHeader(Uint8List bytes) {
    const signature = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
    final searchLength = bytes.length < 1024 ? bytes.length : 1024;
    for (var offset = 0; offset <= searchLength - signature.length; offset++) {
      var matches = true;
      for (var index = 0; index < signature.length; index++) {
        if (bytes[offset + index] != signature[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
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
    ScorePdfDocument document,
    int pageIndex,
  ) =>
      document.renderPage(pageIndex);

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
      _loadedScoreUrl = fileUrl;
    } catch (e) {
      if (mounted) _showSnack('업로드 실패: $e');
    }
  }

  Future<Uint8List?> _preparePickedImage(XFile image) async {
    if (kIsWeb) return image.readAsBytes();

    final cropped = await ImageCropper().cropImage(
      sourcePath: image.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '영역 선택',
          toolbarColor: _primary,
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
              (payload['color'] as String? ?? '#000000').replaceFirst('#', ''),
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
                color: AppColors.inkTertiary,
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
                final bytes = await _preparePickedImage(img);
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
                final bytes = await _preparePickedImage(img);
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
              labelColor: AppColors.inkSecondary,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showColorPicker() {
    // 필기 펜은 도구라 유채색을 그대로 쓴다. 화면 색과는 목적이 다르다.
    const colors = AppColors.pen;
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
              behavior: HitTestBehavior.opaque,
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
                    color: selected ? _primary : Colors.grey.shade300,
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
      'Bandly 방 코드: ${widget.roomCode}\n앱에서 방 참가를 눌러 이 코드를 입력해주세요.';

  Future<void> _copyRoomCode() async {
    await Clipboard.setData(ClipboardData(text: widget.roomCode));
    if (mounted) _showSnack('방 코드가 복사되었습니다.');
  }

  Future<void> _shareRoomCodeToKakao() async {
    try {
      final shared = await PlatformShare.shareRoomText(_roomShareText);
      if (mounted && !shared) {
        await _copyRoomCode();
        _showSnack('공유를 지원하지 않아 방 코드를 복사했습니다.');
      }
    } on PlatformException catch (e) {
      if (mounted) {
        _showSnack('공유 실패: ${e.message ?? e.code}');
      }
    } catch (_) {
      if (mounted) {
        await _copyRoomCode();
        _showSnack('공유 실패로 방 코드를 복사했습니다.');
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
      backgroundColor: AppColors.canvas,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Center(
          // 폭 제한만 남긴다. 폰에서는 화면이 400 이하라 영향이 없고,
          // 웹에서 이걸 빼면 데스크톱 폭 그대로 늘어나 못 쓰게 된다.
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: const BoxDecoration(color: AppColors.surface),
            child: Column(
              children: [
                _buildHeader(),
                _buildExpiryBanner(),
                Expanded(child: _buildTabBody()),
                _buildBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 분리 결과를 화면에 얹는다.
  ///
  /// WebSocket 알림으로 오는 길과, 그 알림을 놓쳐서 직접 물어본 길이 있다.
  /// 둘 다 같은 모양의 payload 를 주므로 처리도 한 곳에서 한다.
  void applySeparationPayload(Map<String, dynamic> payload) {
    final tracksJson = payload['tracks'] as Map<String, dynamic>? ?? {};
    // 재생용 mp3. 변환에 실패한 트랙은 여기에 없고 wav 로 재생된다.
    final streamsJson = payload['streams'] as Map<String, dynamic>? ?? {};
    final results = <TrackResult>[
      for (final entry in _stemLabels.entries)
        if (tracksJson[entry.key] != null)
          TrackResult(
            label: entry.value.$1,
            url: tracksJson[entry.key] as String,
            streamUrl: streamsJson[entry.key] as String?,
            icon: entry.value.$2,
          ),
    ];
    if (results.isEmpty || !mounted) return;

    setState(() {
      _tracks = results;
      // 분석이 실패한 곡이면 null 로 온다. 그때는 파형/코드 없이 재생만 된다.
      _analysisUrl = payload['analysis_url'] as String?;
      _bpmPending = true;
      _bpmResult = null;
      _preferredResultMode = ResultMode.track;
      _tabIndex = 2;
    });
  }

  Future<void> _loadRoomStatus() async {
    if (widget.roomId.isEmpty) return;
    try {
      final data = await ApiService().getRoomStatus(widget.roomId);
      if (!mounted) return;
      setState(() {
        _daysLeft = (data['days_left'] as num?)?.toInt();
        _roomMb = (data['total_mb'] as num?)?.toDouble() ?? 0;
        _showExpiryBanner = data['warn'] == true;
      });
    } catch (_) {
      // 안내를 못 띄우는 것뿐이다. 방을 쓰는 데는 지장이 없다.
    }
  }

  Future<void> _keepRoom() async {
    if (_keeping) return;
    setState(() => _keeping = true);
    try {
      final data = await ApiService().keepRoom(widget.roomId);
      if (!mounted) return;
      setState(() {
        _daysLeft = (data['days_left'] as num?)?.toInt();
        _showExpiryBanner = false;
        _keeping = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(data['message'] as String? ?? '보관했습니다')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _keeping = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('보관 연장에 실패했습니다')),
      );
    }
  }

  /// 정리 예고 띠. 기한이 임박했을 때만 나타난다.
  Widget _buildExpiryBanner() {
    if (!_showExpiryBanner || _daysLeft == null) {
      return const SizedBox.shrink();
    }
    final days = _daysLeft!;
    final size = _roomMb >= 1 ? ' · ${_roomMb.toStringAsFixed(0)}MB' : '';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.schedule_rounded,
            size: 16,
            color: AppColors.inkSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              // 기한이 지나면 방이 통째로 사라진다. 결과물만 지워지는
              // 것처럼 적으면 실제와 다르다.
              days <= 0 ? '곧 이 방이 사라집니다$size' : '$days일 뒤 이 방이 사라집니다$size',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.inkBody,
              ),
            ),
          ),
          TextButton(
            onPressed: _keeping ? null : _keepRoom,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.ink,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              _keeping ? '...' : '보관',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
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
        border: Border.all(color: AppColors.separator),
      ),
      child: Row(
        children: [
          _ToolButton(
            icon: Icons.edit_rounded,
            selected: _tool == DrawTool.pen,
            onTap: () => setState(() => _tool = DrawTool.pen),
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.highlight_rounded,
            selected: _tool == DrawTool.highlighter,
            onTap: () => setState(() => _tool = DrawTool.highlighter),
          ),
          const SizedBox(width: 4),
          _ToolButton(
            icon: Icons.auto_fix_normal_rounded,
            selected: _tool == DrawTool.eraser,
            onTap: () => setState(() => _tool = DrawTool.eraser),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _showColorPicker,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _penColor,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.separator, width: 2),
              ),
            ),
          ),
          const Spacer(),
          _ToolButton(
            icon: Icons.upload_rounded,
            selected: false,
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
          onSeparationRecovered: applySeparationPayload,
          onBpmJobId: (jobId) {
            setState(() => _bpmJobId = jobId);
            _loadBpmResult(jobId);
          },
          onAudioPicked: (bytes, filename) => setState(() {
            _audioBytes = bytes;
            _audioFilename = filename;
          }),
          onAudioUrl: (url) {
            if (mounted) setState(() => _audioUrl = url);
          },
        ),
        ResultTab(
          tracks: _tracks,
          analysisUrl: _analysisUrl,
          audioFilename: _audioFilename,
          audioBytes: _audioBytes,
          audioUrl: _audioUrl,
          bpmJobId: _bpmJobId,
          bpmResult: _bpmResult,
          bpmPending: _bpmPending,
          preferredMode: _preferredResultMode,
        ),
      ],
    );
  }

  Widget _buildScoreTab() {
    return Column(
      children: [
        _buildToolBar(),
        Expanded(child: _buildScoreSurface()),
      ],
    );
  }

  Widget _buildScoreSurface() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.separator),
        ),
        clipBehavior: Clip.hardEdge,
        child: _isLoadingPdf || (_isPdf && _currentDisplayBytes == null)
            ? const Center(child: CircularProgressIndicator(color: _primary))
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
              color: AppColors.fill,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.upload_rounded,
                size: 32, color: AppColors.inkTertiary),
          ),
          const SizedBox(height: 16),
          const Text('악보를 업로드하세요',
              style: TextStyle(fontSize: 14, color: AppColors.inkSecondary)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _showUploadSheet,
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
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
        border: Border(top: BorderSide(color: AppColors.separator)),
      ),
      child: Row(
        children: tabs.asMap().entries.map((entry) {
          final selected = entry.key == _tabIndex;
          return Expanded(
            child: GestureDetector(
              // 기본값(deferToChild)이면 자식이 실제로 그린 픽셀에서만 탭이
              // 먹는다. 아이콘 글리프와 글자만 살아 있고 여백은 죽어서,
              // 조준하듯 눌러야 했다.
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _tabIndex = entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      entry.value['icon'] as IconData,
                      size: 22,
                      color: selected ? _primary : AppColors.inkTertiary,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.value['label'] as String,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected ? _primary : AppColors.inkTertiary,
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
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 도구 종류와 상관없이 같은 색으로 표시한다. 도구마다 색이 다르면
    // "선택됨" 이라는 신호가 아니라 도구의 성격처럼 읽힌다.
    final Color tint = selected ? AppColors.ink : AppColors.inkTertiary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: selected ? tint.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 18, color: tint),
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
                color: AppColors.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: AppColors.inkSecondary),
            )
          : null,
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          color: labelColor ?? AppColors.ink,
          fontWeight: FontWeight.w500,
        ),
        textAlign: icon == null ? TextAlign.center : TextAlign.start,
      ),
      onTap: onTap,
    );
  }
}
