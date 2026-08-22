import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_constants.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../theme/tokens.dart';

enum AnalysisState { idle, loading, done }

/// 분석 카드가 지금 어느 단계를 돌고 있는지. 사용자에게는 한 덩어리지만
/// 서버에서는 분리 작업과 BPM 작업이 차례로 돈다.
enum _Phase { none, separating, bpm }

class AnalysisTab extends StatefulWidget {
  final String roomId;
  final String roomCode;
  final WebSocketService ws;
  final VoidCallback onGoToResult;
  final VoidCallback? onGoToTrackResult;
  final void Function(String jobId)? onBpmJobId;

  /// WebSocket 알림을 놓쳤을 때 직접 물어서 되찾은 분리 결과.
  /// 알림으로 오는 payload 와 같은 모양이라 방 화면은 같은 길로 처리한다.
  final void Function(Map<String, dynamic> payload)? onSeparationRecovered;
  final void Function(Uint8List bytes, String filename)? onAudioPicked;

  /// 업로드된 음원의 서버 주소. 재생은 이 주소로 한다 (웹에서 바이트 재생 불가).
  final void Function(String? url)? onAudioUrl;

  const AnalysisTab({
    super.key,
    required this.roomId,
    required this.roomCode,
    required this.ws,
    required this.onGoToResult,
    this.onGoToTrackResult,
    this.onBpmJobId,
    this.onSeparationRecovered,
    this.onAudioPicked,
    this.onAudioUrl,
  });

  @override
  State<AnalysisTab> createState() => _AnalysisTabState();
}

class _AnalysisTabState extends State<AnalysisTab> {
  static const _primary = AppColors.ink;

  Uint8List? _audioBytes;
  String? _audioFilename;
  String? _audioFileId;
  bool _isUploadingAudio = false;

  /// 분리와 BPM 은 사용자에게 하나의 '분석'이다. 분리가 끝나면 BPM 을
  /// 이어서 돌리고, 그동안 카드 하나가 계속 진행 상태를 보여준다.
  AnalysisState _state = AnalysisState.idle;
  _Phase _phase = _Phase.none;

  double _trackProgress = 0.0;
  String? _trackJobId;
  Timer? _bpmTimeoutTimer;

  /// 서버가 보내오는 단계 메시지. 분리는 몇 분씩 걸리는데 "분리 중" 한 줄만
  /// 떠 있으면 멈춘 건지 도는 건지 알 수 없다. 지나온 단계를 쌓아 보여준다.
  final List<String> _log = [];

  /// 진행률만 바뀌는 메시지가 줄줄이 쌓이지 않도록 마지막 단계를 기억한다.
  String? _lastStage;

  /// 완료 알림을 놓쳤는지 확인하는 타이머.
  ///
  /// 분리 알림은 Redis pub/sub 으로 나가는데 재전송이 없다. 실제로 분리가
  /// 도는 몇 분 사이에 WebSocket 이 keepalive 시간 초과로 끊겨서, 서버는
  /// 멀쩡히 끝났는데 앱만 계속 기다린 적이 있다. 주기적으로 직접 물어본다.
  Timer? _pollTimer;
  static const _pollInterval = Duration(seconds: 12);

  /// 내 앞에 남은 작업 수와 대략 남은 시간.
  ///
  /// 서버가 한 번에 한 곡만 돌리므로, 몇 분이 걸릴지는 내 곡 길이가 아니라
  /// 앞에 몇 명이 있느냐로 정해진다. 그것을 알려주지 않으면 진행률 0% 를
  /// 보며 고장 났다고 여기게 된다.
  int? _queuePosition;
  int? _etaSeconds;

  String get _phaseLabel => switch (_phase) {
        _Phase.separating => '트랙 분리 중',
        _Phase.bpm => 'BPM 분석 중',
        _Phase.none => '',
      };

  @override
  void initState() {
    super.initState();
    _listenWs();
  }

  @override
  void dispose() {
    _bpmTimeoutTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollJob());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 분리가 끝났는지 서버에 직접 묻는다.
  Future<void> _pollJob() async {
    final jobId = _trackJobId;
    if (jobId == null || !mounted) return;

    try {
      // 큐에서 기다리는 동안에는 이쪽이 유일한 소식통이다. 분리가 시작되기
      // 전에는 진행률 알림조차 오지 않는다.
      unawaited(_pollQueue(jobId));

      final data = await ApiService().getTrackList(jobId);
      if (!mounted || _trackJobId != jobId) return;

      final tracks = data['tracks'] as List<dynamic>? ?? [];
      if (data['job_status'] != 'done' || tracks.isEmpty) return;

      _stopPolling();
      setState(() {
        _log.add('완료 알림을 놓쳐 직접 확인함');
        _lastStage = 'recovered';
      });

      // 알림으로 오는 payload 와 같은 모양으로 맞춰 넘긴다.
      widget.onSeparationRecovered?.call(<String, dynamic>{
        'room_id': widget.roomId,
        'job_id': jobId,
        'tracks': <String, dynamic>{
          for (final t in tracks)
            (t as Map<String, dynamic>)['track_type'] as String:
                t['file_url'] as String,
        },
        'streams': data['streams'] ?? <String, dynamic>{},
        'analysis_url': data['analysis_url'],
      });
      _onSeparationDone();
    } catch (_) {
      // 한 번 실패해도 다음 차례에 다시 묻는다.
    }
  }

  Future<void> _pollQueue(String jobId) async {
    try {
      final data = await ApiService().getAnalysisStatus(jobId);
      if (!mounted || _trackJobId != jobId) return;
      setState(() {
        _queuePosition = (data['queue_position'] as num?)?.toInt();
        _etaSeconds = (data['eta_seconds'] as num?)?.toInt();
      });
    } catch (_) {
      // 순번을 못 받아도 분석은 돈다.
    }
  }

  /// '약 12분' 처럼 사람이 읽는 형태. 초 단위까지 보여줄 이유가 없다.
  static String _etaLabel(int seconds) {
    if (seconds < 60) return '1분 이내';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '약 $minutes분';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '약 $hours시간' : '약 $hours시간 $rest분';
  }

  /// 분리가 끝났을 때 공통으로 하는 일. 알림으로 왔든 물어서 알았든 같다.
  void _onSeparationDone() {
    if (!mounted) return;
    _stopPolling();
    setState(() {
      _phase = _Phase.bpm;
      _trackProgress = 0.0;
      _trackJobId = null;
    });
    (widget.onGoToTrackResult ?? widget.onGoToResult)();
    unawaited(_startBpm());
  }

  Map<String, dynamic> _payloadFor(WsEvent event) {
    final payload = event.data['payload'];
    if (payload is Map<String, dynamic>) return payload;
    return event.data;
  }

  bool _belongsToCurrentRoom(Map<String, dynamic> payload) {
    final eventRoomId = payload['room_id'] as String?;
    return eventRoomId == null || eventRoomId == widget.roomId;
  }

  void _listenWs() {
    widget.ws.events.listen((event) {
      if (event.type == WsEventType.audioUploaded) {
        final payload = _payloadFor(event);
        if (!_belongsToCurrentRoom(payload)) return;
        final filename = payload['filename'] as String?;
        final audioFileId = payload['audio_file_id'] as String?;
        final fileUrl = payload['file_url'] as String?;
        if (filename == null || !mounted) return;
        widget.onAudioUrl?.call(fileUrl);

        setState(() {
          final isAnalyzing = _state == AnalysisState.loading;
          if (_audioFilename != filename) {
            _audioBytes = null;
          }
          _audioFilename = filename;
          _audioFileId = audioFileId;
          _isUploadingAudio = false;
          if (!isAnalyzing) {
            _state = AnalysisState.idle;
            _phase = _Phase.none;
            _trackProgress = 0.0;
            _trackJobId = null;
          }
        });
      } else if (event.type == WsEventType.analysisStarted) {
        final payload = _payloadFor(event);
        if (!_belongsToCurrentRoom(payload)) return;
        final jobType = payload['job_type'] as String?;
        final jobId = payload['job_id'] as String?;
        if (!mounted) return;

        setState(() {
          if (jobType == 'bpm') {
            _bpmTimeoutTimer?.cancel();
            _bpmTimeoutTimer = null;
            _state = AnalysisState.loading;
            _phase = _Phase.bpm;
          } else if (jobType == 'separation') {
            _audioFileId ??= payload['audio_file_id'] as String?;
            _state = AnalysisState.loading;
            _phase = _Phase.separating;
            _trackProgress = 0.0;
            _trackJobId = jobId;
          }
        });
      } else if (event.type == WsEventType.bpmAnalyzed) {
        if (mounted) {
          setState(() {
            _log.add('BPM 분석 완료');
            _lastStage = 'bpm_done';
          });
        }
        _bpmTimeoutTimer?.cancel();
        _bpmTimeoutTimer = null;
        final jobId = event.data['job_id'] as String?;
        if (jobId != null) widget.onBpmJobId?.call(jobId);
        if (mounted) {
          setState(() {
            _state = AnalysisState.done;
            _phase = _Phase.none;
          });
        }
      } else if (event.type == WsEventType.trackSeparated) {
        final payload = _payloadFor(event);
        if (!_belongsToCurrentRoom(payload)) return;
        // 분리 결과를 바로 띄우고, BPM 은 뒤에서 이어 돌린다.
        _onSeparationDone();
      } else if (event.type == WsEventType.separationStage) {
        final payload = _payloadFor(event);
        if (!_belongsToCurrentRoom(payload)) return;
        final message = payload['message'] as String?;
        final stage = payload['stage'] as String?;
        if (message == null || !mounted) return;
        setState(() {
          // 같은 단계가 이어지면(분리 진행률처럼) 줄을 바꾸지 않고 덮어쓴다.
          if (stage != null && stage == _lastStage && _log.isNotEmpty) {
            _log[_log.length - 1] = message;
          } else {
            _log.add(message);
            _lastStage = stage;
          }
          if (_log.length > 40) _log.removeAt(0);
        });
      } else if (event.type == WsEventType.separationProgress) {
        final eventJobId = event.data['job_id'] as String?;
        if (_trackJobId != null &&
            eventJobId != null &&
            eventJobId != _trackJobId) {
          return;
        }
        final progress = (event.data['progress'] as num?)?.toDouble() ?? 0;
        if (mounted) {
          setState(() {
            _state = AnalysisState.loading;
            _phase = _Phase.separating;
            _trackJobId ??= eventJobId;
            _trackProgress = progress / 100.0;
          });
        }
      }
    });
  }

  Future<void> _pickAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'flac', 'm4a'],
      withData: true,
    );
    if (result != null && result.files.first.bytes != null) {
      final bytes = result.files.first.bytes!;
      final filename = result.files.first.name;

      // 올리기 전에 거른다. 서버도 막지만, 다 올린 뒤에 거절당하면
      // 모바일 데이터로 수백 MB 를 헛되이 쓴 뒤가 된다.
      if (bytes.length > ApiConstants.maxAudioBytes) {
        _showError(
          '${_formatBytes(bytes.length)} 파일입니다. '
          '${ApiConstants.maxAudioMb}MB 이하만 올릴 수 있어요.',
        );
        return;
      }

      setState(() {
        _audioBytes = bytes;
        _audioFilename = filename;
        _audioFileId = null;
        _isUploadingAudio = true;
        _state = AnalysisState.idle;
        _phase = _Phase.none;
        _trackProgress = 0.0;
        _trackJobId = null;
      });
      widget.onAudioPicked?.call(bytes, filename);
      // 새 파일을 골랐으므로 이전 음원 주소는 무효
      widget.onAudioUrl?.call(null);
      await _uploadSelectedAudio(bytes, filename);
    }
  }

  Future<void> _uploadSelectedAudio(Uint8List bytes, String filename) async {
    try {
      final uploadResult = await ApiService().uploadAudio(
        roomId: widget.roomId,
        bytes: bytes,
        filename: filename,
        purpose: 'separation',
      );
      widget.onAudioUrl?.call(uploadResult['file_url'] as String?);
      if (!mounted) return;
      setState(() {
        _audioFileId = uploadResult['audio_file_id'] as String?;
        _isUploadingAudio = false;
      });
    } catch (e) {
      widget.onAudioUrl?.call(null);
      if (!mounted) return;
      setState(() {
        _audioFileId = null;
        _isUploadingAudio = false;
      });
      _showError(_uploadErrorText(e));
    }
  }

  Future<String?> _ensureAudioUploaded(String purpose) async {
    if (_audioFileId != null) return _audioFileId;
    if (_audioBytes == null || _audioFilename == null) return null;

    setState(() => _isUploadingAudio = true);
    try {
      final uploadResult = await ApiService().uploadAudio(
        roomId: widget.roomId,
        bytes: _audioBytes!,
        filename: _audioFilename!,
        purpose: purpose,
      );
      final audioFileId = uploadResult['audio_file_id'] as String?;
      widget.onAudioUrl?.call(uploadResult['file_url'] as String?);
      if (mounted) {
        setState(() {
          _audioFileId = audioFileId;
          _isUploadingAudio = false;
        });
      }
      return audioFileId;
    } catch (_) {
      if (mounted) {
        setState(() => _isUploadingAudio = false);
      }
      rethrow;
    }
  }

  Future<void> _startBpm() async {
    if (!mounted) return;
    setState(() {
      _state = AnalysisState.loading;
      _phase = _Phase.bpm;
    });
    try {
      final audioFileId = await _ensureAudioUploaded('bpm');
      if (audioFileId == null) {
        throw Exception('업로드된 음원 파일이 없습니다.');
      }
      await ApiService().startBpmAnalysis(
        roomId: widget.roomId,
        audioFileId: audioFileId,
      );
      _bpmTimeoutTimer?.cancel();
      _bpmTimeoutTimer = Timer(const Duration(seconds: 60), () {
        if (mounted && _phase == _Phase.bpm) {
          setState(() {
            _state = AnalysisState.done;
            _phase = _Phase.none;
          });
          _showError('BPM 분석 응답이 없습니다. 결과 화면의 BPM 은 비어 있습니다.');
        }
      });
    } catch (e) {
      // 분리는 이미 끝나 결과가 떠 있다. BPM 만 비워 두고 분석은 완료로 본다.
      if (mounted) {
        setState(() {
          _state = AnalysisState.done;
          _phase = _Phase.none;
        });
        _showError('BPM 분석 실패: $e');
      }
    }
  }

  /// 분리를 띄운다. 완료되면 WS 수신부에서 BPM 을 이어 돌린다.
  Future<void> _startAnalysis() async {
    setState(() {
      _state = AnalysisState.loading;
      _phase = _Phase.separating;
      _trackProgress = 0.0;
      _trackJobId = null;
      _log.clear();
      _lastStage = null;
      _queuePosition = null;
      _etaSeconds = null;
      _log.add('분석 요청을 보내는 중');
    });
    try {
      final audioFileId = await _ensureAudioUploaded('separation');
      if (audioFileId == null) {
        throw Exception('업로드된 음원 파일이 없습니다.');
      }
      final result = await ApiService().startAnalysis(
        roomId: widget.roomId,
        audioFileId: audioFileId,
        jobType: 'separation',
      );
      final jobId = result['job_id'] as String?;
      if (!mounted || _state != AnalysisState.loading) {
        if (jobId != null) {
          ApiService().cancelAnalysis(jobId).catchError((_) {});
        }
        return;
      }
      if (jobId != null) {
        setState(() => _trackJobId = jobId);
        _startPolling();
      }
    } on ApiException catch (e) {
      // 이미 그 방에서 분석이 돌고 있다. 실패가 아니라 그 작업에 붙으면 된다.
      final runningId = e.data?['job_id'] as String?;
      if (e.statusCode == 409 && runningId != null && mounted) {
        setState(() {
          _trackJobId = runningId;
          _log.add('이미 진행 중인 분석에 연결했습니다');
          _lastStage = 'attached';
        });
        _startPolling();
        unawaited(_pollQueue(runningId));
        return;
      }
      if (mounted) {
        setState(() {
          _state = AnalysisState.idle;
          _phase = _Phase.none;
          _trackProgress = 0.0;
          _trackJobId = null;
        });
        _showError(e.userMessage);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = AnalysisState.idle;
          _phase = _Phase.none;
          _trackProgress = 0.0;
          _trackJobId = null;
        });
        _showError('분석을 시작하지 못했습니다. 잠시 후 다시 시도해주세요.');
      }
    }
  }

  void _cancelAnalysis() {
    _bpmTimeoutTimer?.cancel();
    _bpmTimeoutTimer = null;
    _stopPolling();
    final jobId = _trackJobId;
    setState(() {
      _state = AnalysisState.idle;
      _phase = _Phase.none;
      _trackProgress = 0.0;
      _trackJobId = null;
    });
    if (jobId != null) {
      ApiService().cancelAnalysis(jobId).catchError((_) {});
    }
  }

  /// 예외를 그대로 찍으면 'ApiException(413): ...' 처럼 클래스 이름이
  /// 사용자에게 노출된다. 서버가 준 문장만 꺼내 쓴다.
  String _uploadErrorText(Object e) {
    if (e is ApiException) return e.userMessage;
    return '음원 업로드에 실패했습니다. 잠시 후 다시 시도해주세요.';
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 카드는 하나뿐이다. 음원을 올리는 곳과 분석 버튼을 따로 두면 화면에
    // 상자가 두 개 생기는데, 정작 사용자가 하는 일은 하나뿐이다.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          // 악보 탭과 같은 규격의 틀이다. 탭을 오갈 때 상자가 움직이면 안 된다.
          padding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 24),
            // 스크롤 안에서는 높이가 무한이라 Expanded 가 못 쓰인다.
            // IntrinsicHeight 가 높이를 확정시켜 준다.
            child: IntrinsicHeight(child: _buildAudioCard()),
          ),
        );
      },
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }

  Widget _buildAudioCard() {
    final hasAudio = _audioBytes != null || _audioFilename != null;

    return GestureDetector(
      // 음원이 없을 때만 카드 전체가 파일 고르기 버튼이 된다. 음원이 들어온
      // 뒤에는 안에 버튼이 생기므로 아무 데나 눌리면 오히려 방해가 된다.
      behavior: HitTestBehavior.opaque,
      onTap: hasAudio || _isUploadingAudio ? null : _pickAudio,
      child: Padding(
        // 화면에 요소가 이것 하나뿐이라 테두리로 가둘 이유가 없다.
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          children: [
            Expanded(
              // Center 가 폭을 끝까지 밀어줘야 안쪽이 진짜 가운데로 온다.
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  child: _state == AnalysisState.loading
                      ? KeyedSubtree(
                          key: const ValueKey('analyzing'),
                          child: _buildAnalyzing(),
                        )
                      : (hasAudio
                          ? KeyedSubtree(
                              key: const ValueKey('picked'),
                              child: _buildPickedAudio(),
                            )
                          : KeyedSubtree(
                              key: const ValueKey('empty'),
                              child: _buildEmptyUpload(),
                            )),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: _buildActionArea(hasAudio),
            ),
          ],
        ),
      ),
    );
  }

  /// 악보 업로드 화면과 같은 구성이다. 두 화면이 하는 일이 같은데 생김새가
  /// 다르면 탭을 옮길 때마다 다시 읽어야 한다.
  /// 분석이 무엇을 해주는지. 업로드 버튼만 있으면 왜 올려야 하는지 알 수 없다.
  static const _benefits = <(IconData, String, String)>[
    (
      Icons.graphic_eq_rounded,
      '세션 별 음원트랙 분리',
      '보컬 · 드럼 · 베이스 · 기타 · 피아노',
    ),
    (Icons.tune_rounded, '트랙별 조절', '볼륨 · 음소거 · 솔로'),
    (Icons.piano_rounded, '키 조절', '±7 키 변경'),
    (Icons.insights_rounded, '분석', 'BPM · 코드 진행'),
  ];

  Widget _buildEmptyUpload() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _UploadIcon(icon: Icons.upload_rounded),
        const SizedBox(height: AppSpace.lg),
        const Text(
          '음원을 업로드하여 분석해보세요',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: AppColors.inkBody,
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          child: Column(
            children: [
              for (final b in _benefits)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(b.$1, size: 17, color: AppColors.inkTertiary),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              b.$2,
                              style: const TextStyle(
                                fontSize: AppText.footnote,
                                fontWeight: FontWeight.w600,
                                color: AppColors.inkBody,
                              ),
                            ),
                            Text(
                              b.$3,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.inkTertiary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        ElevatedButton.icon(
          onPressed: _pickAudio,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.ink,
            foregroundColor: AppColors.onAccent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: AppSpace.md,
            ),
          ),
          icon: const Icon(Icons.add, size: 18),
          label: const Text(
            '음원 추가',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        // 고르기 전에 조건을 알려준다. 올린 뒤에 거절하는 것보다 낫다.
        const Text(
          'MP3 · WAV · FLAC · M4A · ${ApiConstants.maxAudioMb}MB 이하',
          style: TextStyle(
            fontSize: 11,
            color: AppColors.inkTertiary,
          ),
        ),
      ],
    );
  }

  Widget _buildPickedAudio() {
    final filename = _audioFilename ?? '';
    final dot = filename.lastIndexOf('.');
    final ext = dot > 0 ? filename.substring(dot + 1).toUpperCase() : '음원';

    final meta = [
      if (_audioBytes != null) _formatBytes(_audioBytes!.length),
      ext,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _UploadIcon(icon: Icons.audiotrack_rounded),
        const SizedBox(height: AppSpace.lg),
        Text(
          // 파일명은 길다. 두 줄까지는 보여줘야 어떤 곡인지 알아본다.
          filename,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _isUploadingAudio ? '업로드 중...' : meta.join(' · '),
          style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: _isUploadingAudio || _state == AnalysisState.loading
              ? null
              : _pickAudio,
          style: TextButton.styleFrom(
            foregroundColor: _primary,
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              // 카드가 흰 배경이라 연한 민트 테두리는 거의 안 보인다.
              side: const BorderSide(color: AppColors.separator),
            ),
          ),
          child: const Text(
            '다른 음원 고르기',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  /// 분석이 도는 동안의 카드 가운데. 진행률을 큰 원으로 보여준다.
  ///
  /// 분리는 demucs 가 진행률을 보내주므로 퍼센트가 나오지만, BPM 은 그런 게
  /// 없어서 도는 원으로만 표시한다. 없는 숫자를 지어내지는 않는다.
  Widget _buildAnalyzing() {
    final hasPercent = _phase == _Phase.separating && _trackProgress > 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 168,
          height: 168,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.expand(
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: hasPercent ? _trackProgress : 0),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOut,
                  builder: (BuildContext context, double v, _) =>
                      CircularProgressIndicator(
                    value: hasPercent ? v : null,
                    strokeWidth: 10,
                    strokeCap: StrokeCap.round,
                    backgroundColor: AppColors.fill,
                    // 진행은 강조색이 맡는다. 결과 화면의 재생 바와 같은 규칙.
                    valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                  ),
                ),
              ),
              if (hasPercent)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    // demucs 가 몇 퍼센트씩 건너뛰며 보고한다. 그 사이를
                    // 채워야 숫자가 튀지 않는다.
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: _trackProgress * 100),
                      duration: const Duration(milliseconds: 600),
                      curve: Curves.easeOut,
                      builder: (BuildContext context, double v, _) => Text(
                        '${v.toInt()}',
                        style: const TextStyle(
                          fontSize: 46,
                          fontWeight: FontWeight.bold,
                          color: AppColors.ink,
                          height: 1.0,
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 2),
                      child: Text(
                        '%',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.inkSecondary,
                        ),
                      ),
                    ),
                  ],
                )
              else
                const Icon(
                  Icons.graphic_eq_rounded,
                  size: 40,
                  color: AppColors.inkTertiary,
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text(
          _phaseLabel.isEmpty ? '분석 준비 중' : _phaseLabel,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _audioFilename ?? '',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
        ),
        _buildQueueLine(),
        const SizedBox(height: AppSpace.lg),
        _buildLog(),
      ],
    );
  }

  /// 대기 순번과 남은 시간.
  ///
  /// 서버가 한 번에 한 곡만 돌린다는 사실을 화면이 감추면, 사용자는 자기
  /// 곡이 오래 걸린다고 오해한다.
  Widget _buildQueueLine() {
    final position = _queuePosition;
    final eta = _etaSeconds;
    if (position == null && eta == null) return const SizedBox.shrink();

    final parts = <String>[
      if (position != null && position > 0) '앞에 $position개 대기',
      if (eta != null && eta > 0) _etaLabel(eta),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        parts.join(' · '),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppColors.inkBody,
        ),
      ),
    );
  }

  /// 지나온 단계를 쌓아 보여준다.
  ///
  /// 분리는 몇 분씩 걸린다. 그동안 화면에 원 하나만 돌면 멈춘 것인지 도는
  /// 것인지 알 수 없다. 서버가 단계마다 보내오는 글을 그대로 띄운다.
  Widget _buildLog() {
    if (_log.isEmpty) return const SizedBox.shrink();

    // 마지막 줄이 지금 하는 일이다. 그 위로는 지나온 것이라 흐리게 둔다.
    final int last = _log.length - 1;

    return Container(
      constraints: const BoxConstraints(maxHeight: 132),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < _log.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      i == last ? '▸ ' : '· ',
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            i == last ? AppColors.ink : AppColors.inkTertiary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _log[i],
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          fontWeight:
                              i == last ? FontWeight.w600 : FontWeight.w400,
                          color:
                              i == last ? AppColors.ink : AppColors.inkTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 카드 아래쪽 버튼 자리. 음원이 없으면 아무것도 두지 않는다.
  Widget _buildActionArea(bool hasAudio) {
    if (!hasAudio) return const SizedBox(height: 24);

    if (_state == AnalysisState.loading) {
      return _ActionButton(
        label: '취소',
        color: AppColors.inkTertiary,
        onTap: _cancelAnalysis,
      );
    }

    if (_state == AnalysisState.done) {
      return Column(
        children: [
          // 누를 수 없는 상태 표시다. 채운 사각형으로 두면 버튼으로 오해한다.
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: AppColors.inkSecondary,
              ),
              SizedBox(width: 6),
              Text(
                '분석 완료',
                style: TextStyle(
                  fontSize: AppText.footnote,
                  fontWeight: FontWeight.w500,
                  color: AppColors.inkSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          _ActionButton(
            label: '결과 보기',
            color: _primary,
            onTap: widget.onGoToTrackResult ?? widget.onGoToResult,
          ),
        ],
      );
    }

    return Column(
      children: [
        const Text(
          '트랙 분리 · 파형 · 키 · BPM',
          style: TextStyle(fontSize: 11, color: AppColors.inkTertiary),
        ),
        const SizedBox(height: 8),
        _ActionButton(
          label: _isUploadingAudio ? '음원 업로드 중...' : '분석 시작',
          color: _isUploadingAudio ? AppColors.inkTertiary : _primary,
          onTap: _isUploadingAudio ? null : _startAnalysis,
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionButton({required this.label, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        // 카드가 하나로 합쳐지면서 이 버튼이 화면의 주 동작이 됐다.
        height: 48,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}

/// 악보 탭의 빈 화면과 같은 규격. 크기와 색을 여기서만 바꾸면 둘 다 따라온다.
class _UploadIcon extends StatelessWidget {
  const _UploadIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        color: AppColors.fill,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 32, color: AppColors.inkTertiary),
    );
  }
}
