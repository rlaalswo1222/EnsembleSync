import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
    super.dispose();
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
        if (mounted) {
          setState(() {
            _phase = _Phase.bpm;
            _trackProgress = 0.0;
            _trackJobId = null;
          });
          // 분리 결과를 바로 띄우고, BPM 은 뒤에서 이어 돌린다.
          (widget.onGoToTrackResult ?? widget.onGoToResult)();
          unawaited(_startBpm());
        }
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
      _showError('음원 업로드 실패: $e');
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
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = AnalysisState.idle;
          _phase = _Phase.none;
          _trackProgress = 0.0;
          _trackJobId = null;
        });
        _showError('분석 요청 실패: $e');
      }
    }
  }

  void _cancelAnalysis() {
    _bpmTimeoutTimer?.cancel();
    _bpmTimeoutTimer = null;
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
      onTap: hasAudio || _isUploadingAudio ? null : _pickAudio,
      child: Padding(
        // 화면에 요소가 이것 하나뿐이라 테두리로 가둘 이유가 없다.
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          children: [
            Expanded(
              // Center 가 폭을 끝까지 밀어줘야 안쪽이 진짜 가운데로 온다.
              child: Center(
                child: _state == AnalysisState.loading
                    ? _buildAnalyzing()
                    : (hasAudio ? _buildPickedAudio() : _buildEmptyUpload()),
              ),
            ),
            _buildActionArea(hasAudio),
          ],
        ),
      ),
    );
  }

  /// 악보 업로드 화면과 같은 구성이다. 두 화면이 하는 일이 같은데 생김새가
  /// 다르면 탭을 옮길 때마다 다시 읽어야 한다.
  Widget _buildEmptyUpload() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _UploadIcon(icon: Icons.upload_rounded),
        const SizedBox(height: AppSpace.lg),
        const Text(
          '음원을 업로드하세요',
          style: TextStyle(fontSize: 14, color: AppColors.inkSecondary),
        ),
        const SizedBox(height: AppSpace.lg),
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
                child: CircularProgressIndicator(
                  value: hasPercent ? _trackProgress : null,
                  strokeWidth: 10,
                  strokeCap: StrokeCap.round,
                  backgroundColor: AppColors.fill,
                  valueColor: const AlwaysStoppedAnimation(_primary),
                ),
              ),
              if (hasPercent)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${(_trackProgress * 100).toInt()}',
                      style: const TextStyle(
                        fontSize: 46,
                        fontWeight: FontWeight.bold,
                        color: AppColors.ink,
                        height: 1.0,
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
        const SizedBox(height: 20),
        // 두 작업이 차례로 도는 걸 알려준다. 분리가 끝났는데 아직 기다려야
        // 하는 이유가 화면에 없으면 멈춘 것처럼 보인다.
        _StepRow(
          index: 1,
          label: '트랙 분리',
          done: _phase == _Phase.bpm,
          active: _phase == _Phase.separating,
        ),
        const SizedBox(height: 8),
        _StepRow(
          index: 2,
          label: 'BPM 분석',
          done: false,
          active: _phase == _Phase.bpm,
        ),
      ],
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

/// 분석 단계 한 줄. 끝난 단계는 체크, 도는 단계는 진한 글씨로 구분한다.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.label,
    required this.done,
    required this.active,
  });

  final int index;
  final String label;
  final bool done;
  final bool active;

  static const _primary = AppColors.ink;

  @override
  Widget build(BuildContext context) {
    final color = done || active ? _primary : AppColors.inkTertiary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? _primary : Colors.transparent,
            border: Border.all(
              color: done || active ? _primary : AppColors.inkTertiary,
              width: 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: done
              ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
              : Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: color,
          ),
        ),
        if (done) ...[
          const SizedBox(width: 6),
          const Text(
            '완료',
            style: TextStyle(fontSize: 11, color: AppColors.inkTertiary),
          ),
        ],
      ],
    );
  }
}
