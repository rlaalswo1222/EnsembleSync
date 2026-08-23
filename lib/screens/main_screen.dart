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
import '../services/recent_rooms.dart';
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

  /// 내가 그은 획을 그은 순서대로 담아 둔다. 되돌리기가 여기서 하나씩 꺼낸다.
  ///
  /// 남이 그은 것까지 되돌리면 안 된다. 같은 악보를 함께 보는 방에서
  /// 내 되돌리기 단추가 옆 사람의 필기를 지우면 그건 사고다.
  ///
  /// 페이지마다 따로 쌓는다. 3쪽에서 되돌리기를 눌렀는데 1쪽의 필기가
  /// 사라지면 무슨 일이 났는지 알 수가 없다.
  final Map<int, List<String>> _myStrokeIds = {};

  List<String> _myIdsForPage(int page) => _myStrokeIds[page] ??= <String>[];

  bool get _canUndo => _myIdsForPage(_currentPdfPage).isNotEmpty;
  Stroke? _currentStroke;
  DrawTool _tool = DrawTool.pen;
  Color _penColor = _primary;

  /// 도구마다 굵기를 따로 기억한다.
  ///
  /// 하나로 묶으면 펜을 얇게 쓰다가 형광펜으로 바꾸는 순간 형광펜이
  /// 실선처럼 가늘어진다. 셋은 쓰임이 달라서 알맞은 굵기도 다르다.
  final Map<DrawTool, double> _toolWidths = <DrawTool, double>{
    DrawTool.pen: 3,
    DrawTool.highlighter: 18,
    DrawTool.eraser: 20,
  };

  /// 도구별로 고를 수 있는 굵기.
  ///
  /// 자유롭게 정하는 슬라이더 대신 몇 개만 둔다. 악보에 쓰는 굵기는
  /// 사실상 '얇게 · 보통 · 굵게' 면 충분하고, 손가락으로 미세하게 맞추는
  /// 것은 오히려 성가시다.
  static const Map<DrawTool, List<double>> _widthChoices =
      <DrawTool, List<double>>{
    DrawTool.pen: <double>[1.5, 3, 5, 8],
    DrawTool.highlighter: <double>[12, 18, 26],
    DrawTool.eraser: <double>[12, 20, 32],
  };

  double get _currentWidth => _toolWidths[_tool] ?? 3;

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

  /// 주소에서 파일 경로만 남긴다.
  ///
  /// 서버가 주는 주소에는 유효기간 서명이 쿼리로 붙어 있다. 같은 악보라도
  /// 받을 때마다 뒤가 달라지므로, "이미 불러온 파일인가" 를 통째로 비교하면
  /// 매번 새 파일로 보인다. 확장자를 볼 때도 마찬가지다 — 주소 끝이
  /// sig 값이라 .pdf 로 끝나지 않는다.
  static String _fileKey(String url) {
    final Uri? parsed = Uri.tryParse(url);
    return parsed == null || parsed.path.isEmpty ? url : parsed.path;
  }

  int _tabIndex = 0;

  /// 악보를 넓게 펼 수 있는 화면인가.
  ///
  /// 태블릿을 말한다. 이때는 도구를 위가 아니라 왼쪽에 세운다. 위를
  /// 가로지르는 도구 줄은 폭이 남아도 세로만 깎아먹는다.
  ///
  /// 600 은 태블릿과 폰을 가르는 흔한 기준이다. 앱은 세로로 고정돼 있으므로
  /// 폰이 이 값을 넘는 일은 없다.
  static bool _isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 600;

  /// 스템 이름 → (화면 이름, 아이콘). 순서가 곧 화면에 쌓이는 순서다.
  ///
  /// 'other' 를 '기타'로 부르던 때가 있었다. 지금 쓰는 4트랙 모델에서
  /// 이 트랙은 기타뿐 아니라 건반·현악까지 남은 것을 전부 담으므로
  /// '나머지'가 맞다.
  ///
  /// guitar·piano 는 6트랙 모델로 되돌릴 때를 위해 남겨둔다. 서버가 안
  /// 주면 화면에도 안 나온다.
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

  /// 마지막으로 파일 주소를 새로 받아온 시각. 되풀이를 막는 데 쓴다.
  DateTime? _lastUrlRefresh;

  /// 방을 빠져나가는 중. 여러 요청이 한꺼번에 401 을 받아도 한 번만 돈다.
  bool _leaving = false;

  /// 믹서를 처음부터 다시 만들라는 신호.
  ///
  /// 주소를 새로 받으면 서명이 달라져서 문자열이 매번 바뀐다. 결과 탭이
  /// 주소를 그대로 key 에 쓰면 앱으로 돌아올 때마다 트랙 수십 MB 를 다시
  /// 받게 된다. 그래서 key 는 파일 경로로 고정하고, 정말 다시 불러와야 할
  /// 때만 이 값을 올린다.
  int _mixerReloadToken = 0;

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
      // 파일 주소도 그새 만료됐을 수 있다. 재생을 누르고 나서 실패하는
      // 것보다 돌아온 김에 새로 받아두는 편이 낫다.
      unawaited(_refreshFileUrls());
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
    _restoreRoomContents();
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
              // 이미 사라진 획을 되돌리기가 다시 지우려 들면 안 된다.
              for (final ids in _myStrokeIds.values) {
                ids.remove(id);
              }
            });
          }
          break;
        case WsEventType.clear:
          setState(() {
            _pageStrokes.clear();
            _myStrokeIds.clear();
          });
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
    final String key = _fileKey(fileUrl);
    if (_loadingScoreUrl == key || _loadedScoreUrl == key) return;
    _loadingScoreUrl = key;
    try {
      final bytes = await ApiService().downloadScore(fileUrl);
      if (!mounted) return;
      if (key.toLowerCase().endsWith('.pdf')) {
        final loaded = await _loadPdfPages(bytes);
        if (!loaded) return;
      } else {
        await _showImageScore(bytes);
      }
      _loadedScoreUrl = key;
    } catch (e) {
      debugPrint('Score download failed: $e');
      if (mounted) _showSnack('악보를 불러오지 못했습니다. 잠시 후 다시 시도해주세요.');
    } finally {
      if (_loadingScoreUrl == key) _loadingScoreUrl = null;
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
        _myStrokeIds.clear();
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
      _myStrokeIds.clear();
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
      _loadedScoreUrl = _fileKey(fileUrl);
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
      // 보낸 쪽이 정한 굵기를 그대로 쓴다.
      //
      // 예전에는 도구 종류만 보고 이쪽에서 굵기를 정했다. 그러면 상대가
      // 얇게 그은 선이 내 화면에서는 굵게 보인다. 같은 악보를 함께 보는
      // 앱에서 이건 그냥 다른 그림이다.
      //
      // 굵기를 안 보내던 시절의 기록에는 값이 없다. 그때 쓰던 값을
      // 그대로 넣어 예전 필기도 지금과 같게 보이게 한다.
      width: (payload['stroke_width'] as num?)?.toDouble() ??
          (isEraser
              ? 20.0
              : isHighlighter
                  ? 18.0
                  : 3.0),
      isEraser: isEraser,
      isHighlighter: isHighlighter,
    );
  }

  /// 내가 마지막으로 그은 획을 지운다.
  ///
  /// 서버가 스냅샷에서도 빼 주므로 나중에 들어온 사람에게도 되살아나지
  /// 않는다.
  void _undo() {
    final List<String> mine = _myIdsForPage(_currentPdfPage);
    if (mine.isEmpty) return;
    final String id = mine.removeLast();
    setState(() {
      for (final List<Stroke> strokes in _pageStrokes.values) {
        strokes.removeWhere((Stroke s) => s.id == id);
      }
    });
    _ws.sendErase(id);
  }

  /// 방의 필기를 전부 지운다.
  ///
  /// 남의 것까지 사라지고 되돌릴 수 없으므로 반드시 한 번 묻는다.
  Future<void> _clearAll() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: const Text('필기를 전부 지울까요?'),
        content: const Text(
          '이 방의 모든 페이지에서 모두의 필기가 사라집니다. 되돌릴 수 없습니다.',
          style: TextStyle(color: AppColors.inkBody),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소',
                style: TextStyle(color: AppColors.inkSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('전부 지우기',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _pageStrokes.clear();
      _myStrokeIds.clear();
    });
    _ws.sendClear();
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

  /// 도구를 누른다. 이미 고른 도구를 다시 누르면 굵기를 정하는 창이 뜬다.
  ///
  /// 굵기 단추를 따로 두면 도구 줄이 두 배로 길어진다. 고른 것을 다시
  /// 누르면 자세히 볼 수 있다는 것은 필기 앱에서 흔한 약속이라, 한 번쯤
  /// 눌러보면 알게 된다.
  void _onToolTap(DrawTool tool) {
    if (_tool == tool) {
      _showToolOptions(tool);
      return;
    }
    setState(() => _tool = tool);
  }

  static String _toolName(DrawTool tool) => switch (tool) {
        DrawTool.pen => '펜',
        DrawTool.highlighter => '형광펜',
        DrawTool.eraser => '지우개',
      };

  void _showToolOptions(DrawTool tool) {
    final List<double> choices = _widthChoices[tool] ?? const <double>[3];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (BuildContext context, StateSetter refresh) {
          void pick(double width) {
            setState(() => _toolWidths[tool] = width);
            refresh(() {});
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${_toolName(tool)} 굵기',
                    style: const TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Row(
                    children: <Widget>[
                      for (final double width in choices) ...<Widget>[
                        Expanded(
                          child: _WidthChoice(
                            width: width,
                            // 지우개는 색이 없다. 굵기만 보여주면 되므로
                            // 무채색으로 그린다.
                            color: tool == DrawTool.eraser
                                ? AppColors.inkSecondary
                                : _penColor,
                            selected: _toolWidths[tool] == width,
                            onTap: () => pick(width),
                          ),
                        ),
                        if (width != choices.last)
                          const SizedBox(width: AppSpace.sm),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
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

  /// 필기 좌표는 ScoreCanvas 가 이미 0~1 로 만들어 준다.
  ///
  /// 예전에는 여기서 화면 크기로 나눴는데, 그러면 악보가 화면 어디에 어떻게
  /// 놓였는지 모르는 채로 계산하는 셈이다. 확대까지 들어오면서 그 계산은
  /// 악보를 그리는 쪽만 할 수 있게 됐다.
  void _onStrokeStart(Offset norm) {
    final id = '${widget.nickname}_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _currentStroke = Stroke(
        id: id,
        points: [norm],
        color: _tool == DrawTool.eraser ? Colors.white : _penColor,
        width: _currentWidth,
        isEraser: _tool == DrawTool.eraser,
        isHighlighter: _tool == DrawTool.highlighter,
      );
    });
  }

  void _onStrokeUpdate(Offset norm) {
    if (_currentStroke == null) return;
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

  /// 그리려던 것이 아니었다. 두 손가락으로 확대하려다 한쪽이 먼저 닿은
  /// 것이므로 그리던 획을 버린다.
  void _onStrokeCancel() {
    if (_currentStroke == null) return;
    setState(() => _currentStroke = null);
  }

  void _onStrokeEnd() {
    if (_currentStroke == null) return;
    final stroke = _currentStroke!;
    setState(() {
      _strokes.add(stroke);
      _myIdsForPage(_currentPdfPage).add(stroke.id);
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
      'stroke_width': stroke.width,
      'color':
          '#${stroke.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      'stroke_data': stroke.points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
      'is_deleted': false,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

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
        child: Container(
          decoration: const BoxDecoration(color: AppColors.surface),
          // 폭 제한을 화면 단위가 아니라 탭 단위로 옮겼다.
          //
          // 예전에는 방 화면 전체를 400 으로 묶었다. 폰에서는 화면이 그보다
          // 좁아 영향이 없었지만, 태블릿에서는 그 넓은 화면을 두고 가운데
          // 400 짜리 기둥만 쓰게 된다. 악보를 보는 앱에서 이건 치명적이다.
          //
          // 악보는 넓을수록 좋고, 분석·결과는 너무 늘어지면 읽기 나쁘다.
          // 그래서 필요한 쪽에서만 묶는다.
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
    );
  }

  /// 분리 결과를 화면에 얹는다.
  ///
  /// WebSocket 알림으로 오는 길과, 그 알림을 놓쳐서 직접 물어본 길이 있다.
  /// 둘 다 같은 모양의 payload 를 주므로 처리도 한 곳에서 한다.
  ///
  /// [switchTab] 은 분석이 방금 끝났을 때만 켠다. 사용자가 기다리던 결과라
  /// 바로 보여주는 것이 맞다. 반대로 파일 주소만 조용히 새로 받는 길에서는
  /// 꺼야 한다 — 그쪽은 사용자가 아무것도 요청하지 않았는데 화면이 바뀌는
  /// 셈이 된다.
  void applySeparationPayload(
    Map<String, dynamic> payload, {
    bool switchTab = true,
  }) {
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
      if (switchTab) _tabIndex = 2;
    });
  }

  /// 방에 이미 있던 음원과 분석 결과를 불러온다.
  ///
  /// 악보와 필기는 원래 API 로 복원하는데 음원과 분석은 WebSocket 알림에만
  /// 기대고 있었다. 알림은 지나가면 끝이라 나중에 들어온 사람은 빈 화면을
  /// 봤다. 서버에는 있는데 볼 길이 없었던 셈이다.
  Future<void> _restoreRoomContents({bool switchTab = true}) async {
    if (widget.roomId.isEmpty) return;
    try {
      final data = await ApiService().getRoomLatest(widget.roomId);
      if (!mounted) return;

      final audio = data['audio'] as Map<String, dynamic>?;
      if (audio != null) {
        setState(() => _audioUrl = audio['file_url'] as String?);
      }

      final separation = data['separation'] as Map<String, dynamic>?;
      if (separation != null) {
        // 알림으로 올 때와 같은 모양이라 같은 길로 처리한다.
        applySeparationPayload(separation, switchTab: switchTab);
        // 복원은 새 분석이 아니다. BPM 을 기다리는 표시를 띄우면 안 된다.
        setState(() {
          _bpmPending = false;
          // 주소만 새로 받는 경우에는 보던 화면을 그대로 둔다. 앱으로
          // 돌아올 때마다 악보 탭으로 끌려가면 안 된다.
          if (switchTab) _tabIndex = 0;
        });
      }

      final bpmJobId = data['bpm_job_id'] as String?;
      if (bpmJobId != null) {
        setState(() => _bpmJobId = bpmJobId);
        _loadBpmResult(bpmJobId);
      }
    } catch (_) {
      // 복원에 실패해도 방은 쓸 수 있다. 새로 분석하면 채워진다.
    }
  }

  /// 파일 주소가 만료됐을 때 새로 받아온다.
  ///
  /// 서버가 내려주는 음원·트랙 주소에는 유효기간이 있다. 링크가 새어
  /// 나가도 하루 뒤에는 죽게 하려는 것인데, 그 대신 앱을 오래 켜둔 채
  /// 재생을 누르면 만료된 주소를 쥐고 있을 수 있다. 그때 다시 물어보면
  /// 서버가 그 자리에서 새로 서명해서 준다. 파일도 분석 결과도 그대로라
  /// 다시 분석하는 일은 없다.
  ///
  /// 짧은 간격으로 거듭 부르지 않는다. 주소를 새로 받아도 여전히 실패하는
  /// 상황(서버가 멈췄다든가)에서 끝없이 되풀이하게 된다.
  Future<void> _refreshFileUrls() async {
    final now = DateTime.now();
    if (_lastUrlRefresh != null &&
        now.difference(_lastUrlRefresh!) < const Duration(seconds: 30)) {
      return;
    }
    _lastUrlRefresh = now;
    await _restoreRoomContents(switchTab: false);
  }

  /// 트랙을 못 불러왔을 때. 주소를 새로 받고 믹서를 다시 만들게 한다.
  ///
  /// 앱으로 돌아왔을 때 하는 갱신과 갈라 둔다. 그쪽은 주소만 조용히
  /// 새것으로 바꾸면 되지만, 이쪽은 이미 실패한 뒤라 실제로 다시 받아야
  /// 한다.
  Future<void> _recoverFileUrls() async {
    final String before = _tracks.map((t) => t.url).join('|');
    await _refreshFileUrls();
    if (!mounted) return;
    // 주소가 그대로면 다시 만들어도 같은 자리에서 또 실패한다. 실패가
    // 다시 이 함수를 부르므로 그대로 두면 끝없이 돈다. 갱신이 실제로
    // 새 주소를 가져왔을 때만 다시 만든다.
    if (_tracks.map((t) => t.url).join('|') != before) {
      setState(() => _mixerReloadToken++);
    }
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
    } on ApiException catch (e) {
      // 이 방의 열쇠가 더 이상 통하지 않는다. 방이 정리됐거나 토큰이
      // 무효가 된 것이다. 빈 화면을 붙들고 있게 두지 말고 되돌린다.
      if (e.statusCode == 401) _leaveRoom();
    } catch (_) {
      // 안내를 못 띄우는 것뿐이다. 방을 쓰는 데는 지장이 없다.
    }
  }

  /// 열쇠가 통하지 않을 때 첫 화면으로 되돌린다.
  ///
  /// 이 방은 목록에서도 지운다. 남겨두면 눌러도 들어가지지 않는 항목이
  /// 계속 보인다.
  Future<void> _leaveRoom() async {
    if (_leaving) return;
    _leaving = true;
    await RecentRooms.forget(widget.roomId);
    ApiService.roomToken = null;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('방에 접근할 수 없습니다. 방 코드로 다시 입장해주세요.')),
    );
    Navigator.of(context).popUntil((route) => route.isFirst);
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
          for (final Widget item in _toolItems()) ...[
            item,
            const SizedBox(width: 6),
          ],
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
        _readable(AnalysisTab(
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
        )),
        _wide(ResultTab(
          tracks: _tracks,
          analysisUrl: _analysisUrl,
          audioFilename: _audioFilename,
          audioBytes: _audioBytes,
          audioUrl: _audioUrl,
          bpmJobId: _bpmJobId,
          bpmResult: _bpmResult,
          bpmPending: _bpmPending,
          preferredMode: _preferredResultMode,
          onUrlsExpired: _recoverFileUrls,
          reloadToken: _mixerReloadToken,
        )),
      ],
    );
  }

  /// 글과 조작이 늘어지지 않도록 폭을 묶는다.
  ///
  /// 분석 화면은 카드 하나에 업로드 단추가 전부라 넓다고 좋아지지 않는다.
  /// 화면을 가로지르는 단추는 오히려 누르기 나쁘다.
  Widget _readable(Widget child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: child,
        ),
      );

  /// 넓을수록 좋은 화면.
  ///
  /// 파형은 시간을 가로로 펼친 그림이다. 폭이 넓어지면 같은 곡이 더 잘게
  /// 보이므로 어디서 소리가 들고 나는지 훨씬 잘 읽힌다. 태블릿에서 좌우를
  /// 비워두는 것은 그냥 손해다.
  ///
  /// 그래도 한계는 둔다. 데스크톱 웹에서 2000 픽셀짜리 재생 바가 나오면
  /// 손이 화면을 가로질러야 한다.
  Widget _wide(Widget child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: child,
        ),
      );

  Widget _buildScoreTab() {
    // 넓은 화면에서는 도구를 왼쪽에 세운다. 가로에서는 세로 공간이 귀한데
    // 도구 줄이 위를 가로지르면 악보가 그만큼 납작해진다.
    if (_isWide(context)) {
      return Row(
        children: [
          _buildToolRail(),
          Expanded(child: _buildScoreSurface()),
        ],
      );
    }
    return Column(
      children: [
        _buildToolBar(),
        Expanded(child: _buildScoreSurface()),
      ],
    );
  }

  /// 도구 목록. 가로줄과 세로줄이 같은 것을 담는다.
  List<Widget> _toolItems() => <Widget>[
        _ToolButton(
          icon: Icons.edit_rounded,
          selected: _tool == DrawTool.pen,
          hasOptions: true,
          onTap: () => _onToolTap(DrawTool.pen),
        ),
        _ToolButton(
          icon: Icons.highlight_rounded,
          selected: _tool == DrawTool.highlighter,
          hasOptions: true,
          onTap: () => _onToolTap(DrawTool.highlighter),
        ),
        _ToolButton(
          icon: Icons.auto_fix_normal_rounded,
          selected: _tool == DrawTool.eraser,
          hasOptions: true,
          onTap: () => _onToolTap(DrawTool.eraser),
        ),
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
        // 되돌릴 것이 없으면 흐리게 둔다. 눌러도 아무 일이 없는 단추가
        // 멀쩡해 보이면 고장인지 아닌지 알 수가 없다.
        _ToolButton(
          icon: Icons.undo_rounded,
          selected: false,
          enabled: _canUndo,
          onTap: _undo,
        ),
        _ToolButton(
          icon: Icons.layers_clear_rounded,
          selected: false,
          onTap: _clearAll,
        ),
      ];

  /// 왼쪽에 세우는 도구 줄.
  Widget _buildToolRail() {
    return Container(
      width: 60,
      margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.separator),
      ),
      child: Column(
        children: [
          for (final Widget item in _toolItems()) ...[
            item,
            const SizedBox(height: 10),
          ],
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
      onStrokeStart: _onStrokeStart,
      onStrokeUpdate: _onStrokeUpdate,
      onStrokeEnd: _onStrokeEnd,
      onStrokeCancel: _onStrokeCancel,
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

  /// 눌렀을 때 더 볼 것이 있는가. 고른 도구에는 굵기를 정하는 창이 있다.
  final bool hasOptions;

  /// 지금 쓸 수 있는가. 되돌릴 것이 없을 때의 되돌리기 단추가 그렇다.
  final bool enabled;

  const _ToolButton({
    required this.icon,
    required this.selected,
    required this.onTap,
    this.hasOptions = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // 도구 종류와 상관없이 같은 색으로 표시한다. 도구마다 색이 다르면
    // "선택됨" 이라는 신호가 아니라 도구의 성격처럼 읽힌다.
    final Color tint = !enabled
        ? AppColors.separator
        : selected
            ? AppColors.ink
            : AppColors.inkTertiary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: selected ? tint.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Icon(icon, size: 18, color: tint),
            // 고른 도구의 오른쪽 아래에 작은 표시를 둔다. 다시 누르면
            // 굵기를 정할 수 있다는 것을 알 방법이 달리 없다.
            if (selected && hasOptions)
              Positioned(
                right: 3,
                bottom: 3,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: tint,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
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

/// 굵기 하나를 고르는 단추.
///
/// 숫자 대신 그 굵기의 선을 그대로 보여준다. '5' 가 얼마나 굵은지는
/// 아무도 모르지만, 그어진 선은 바로 안다.
class _WidthChoice extends StatelessWidget {
  const _WidthChoice({
    required this.width,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 56,
        decoration: BoxDecoration(
          color: selected ? AppColors.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? AppColors.ink : AppColors.separator,
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Container(
            width: 34,
            height: width,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(width / 2),
            ),
          ),
        ),
      ),
    );
  }
}
