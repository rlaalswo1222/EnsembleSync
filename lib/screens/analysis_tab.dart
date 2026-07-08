import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';

enum AnalysisState { idle, loading, done }

class AnalysisTab extends StatefulWidget {
  final String roomId;
  final String roomCode;
  final WebSocketService ws;
  final VoidCallback onGoToResult;
  final VoidCallback? onGoToTrackResult;
  final void Function(String jobId)? onBpmJobId;
  final void Function(Uint8List bytes, String filename)? onAudioPicked;

  const AnalysisTab({
    super.key,
    required this.roomId,
    required this.roomCode,
    required this.ws,
    required this.onGoToResult,
    this.onGoToTrackResult,
    this.onBpmJobId,
    this.onAudioPicked,
  });

  @override
  State<AnalysisTab> createState() => _AnalysisTabState();
}

class _AnalysisTabState extends State<AnalysisTab> {
  static const _primary = Color(0xFF0F766E);

  Uint8List? _audioBytes;
  String? _audioFilename;
  String? _audioFileId;
  bool _isUploadingAudio = false;

  AnalysisState _bpmState = AnalysisState.idle;
  AnalysisState _pitchState = AnalysisState.idle;
  AnalysisState _trackState = AnalysisState.idle;

  double _trackProgress = 0.0;
  String? _trackJobId;
  Timer? _bpmTimeoutTimer;

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
        if (filename == null || !mounted) return;

        setState(() {
          final isAnalyzing = _trackState == AnalysisState.loading ||
              _bpmState == AnalysisState.loading ||
              _pitchState == AnalysisState.loading;
          if (_audioFilename != filename) {
            _audioBytes = null;
          }
          _audioFilename = filename;
          _audioFileId = audioFileId;
          _isUploadingAudio = false;
          if (!isAnalyzing) {
            _bpmState = AnalysisState.idle;
            _pitchState = AnalysisState.idle;
            _trackState = AnalysisState.idle;
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
            _bpmState = AnalysisState.loading;
          } else if (jobType == 'separation') {
            _audioFileId ??= payload['audio_file_id'] as String?;
            _trackState = AnalysisState.loading;
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
          setState(() => _bpmState = AnalysisState.done);
          widget.onGoToResult();
        }
      } else if (event.type == WsEventType.trackSeparated) {
        final payload = _payloadFor(event);
        if (!_belongsToCurrentRoom(payload)) return;
        if (mounted) {
          setState(() {
            _trackState = AnalysisState.done;
            _trackProgress = 1.0;
            _trackJobId = null;
          });
          (widget.onGoToTrackResult ?? widget.onGoToResult)();
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
            _trackState = AnalysisState.loading;
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
        _bpmState = AnalysisState.idle;
        _pitchState = AnalysisState.idle;
        _trackState = AnalysisState.idle;
        _trackProgress = 0.0;
        _trackJobId = null;
      });
      widget.onAudioPicked?.call(bytes, filename);
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
      if (!mounted) return;
      setState(() {
        _audioFileId = uploadResult['audio_file_id'] as String?;
        _isUploadingAudio = false;
      });
    } catch (e) {
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
    setState(() => _bpmState = AnalysisState.loading);
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
        if (mounted && _bpmState == AnalysisState.loading) {
          setState(() => _bpmState = AnalysisState.idle);
          _showError('BPM 분석 응답이 없습니다. 다시 시도해주세요.');
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _bpmState = AnalysisState.idle);
        _showError('BPM 분석 실패: $e');
      }
    }
  }

  Future<void> _startPitch() async {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          '미구현 기능',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '피치 분석 기능은 현재 개발 중입니다.',
          style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              '확인',
              style: TextStyle(color: _primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startTrack() async {
    setState(() {
      _trackState = AnalysisState.loading;
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
      if (!mounted || _trackState != AnalysisState.loading) {
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
          _trackState = AnalysisState.idle;
          _trackProgress = 0.0;
          _trackJobId = null;
        });
        _showError('트랙 분리 요청 실패: $e');
      }
    }
  }

  void _cancelTrack() {
    final jobId = _trackJobId;
    setState(() {
      _trackState = AnalysisState.idle;
      _trackProgress = 0.0;
      _trackJobId = null;
    });
    if (jobId != null) {
      ApiService().cancelAnalysis(jobId).catchError((_) {});
    }
  }

  void _clearAudio() {
    final jobId = _trackState == AnalysisState.loading ? _trackJobId : null;
    setState(() {
      _audioBytes = null;
      _audioFilename = null;
      _audioFileId = null;
      _isUploadingAudio = false;
      _bpmState = AnalysisState.idle;
      _pitchState = AnalysisState.idle;
      _trackState = AnalysisState.idle;
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _buildAudioUploadArea(),
          const SizedBox(height: 12),
          _buildAnalysisCard(
            icon: Icons.content_cut_rounded,
            title: '트랙 분리',
            subtitle: '보컬/드럼/베이스/기타를 분리합니다',
            state: _trackState,
            onStart: _startTrack,
            onResult: widget.onGoToTrackResult ?? widget.onGoToResult,
            onCancel: _cancelTrack,
            buttonLabel: '분리 시작',
            progressValue: _trackProgress,
            enabled: !_isUploadingAudio,
          ),
          const SizedBox(height: 12),
          _buildAnalysisCard(
            icon: Icons.graphic_eq_rounded,
            title: 'BPM 분석',
            subtitle: '구간별 템포 이탈을 확인하세요',
            state: _bpmState,
            onStart: _startBpm,
            onResult: widget.onGoToResult,
            onCancel: () => setState(() => _bpmState = AnalysisState.idle),
            enabled: !_isUploadingAudio && _trackState == AnalysisState.done,
          ),
          const SizedBox(height: 12),
          _buildAnalysisCard(
            icon: Icons.music_note_rounded,
            title: '피치 분석',
            subtitle: '보컬 음정 이탈 구간을 확인하세요',
            state: _pitchState,
            onStart: _startPitch,
            onResult: widget.onGoToResult,
            onCancel: () => setState(() => _pitchState = AnalysisState.idle),
            enabled: !_isUploadingAudio && _trackState == AnalysisState.done,
          ),
        ],
      ),
    );
  }

  Widget _buildAudioUploadArea() {
    if (_audioBytes == null && _audioFilename == null) {
      return GestureDetector(
        onTap: _pickAudio,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFD1D5DB)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.upload_rounded, color: Color(0xFF9CA3AF), size: 20),
              SizedBox(width: 8),
              Text(
                '음원 파일 업로드 (MP3, WAV)',
                style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDFA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.audio_file_rounded, color: _primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _audioFilename ?? '',
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF1A1A2E),
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: _clearAudio,
            child: const Icon(Icons.close_rounded,
                size: 18, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required AnalysisState state,
    required VoidCallback onStart,
    required VoidCallback onResult,
    VoidCallback? onCancel,
    String buttonLabel = '분석 시작',
    double progressValue = 0.0,
    bool enabled = true,
  }) {
    final hasAudio = _audioFileId != null || _audioBytes != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Color(0xFFF0FDFA),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: _primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (state == AnalysisState.idle)
            if (!enabled)
              const _ActionButton(
                label: '트랙 분리 후 사용 가능',
                color: Color(0xFFD1D5DB),
                onTap: null,
              )
            else
              _ActionButton(
                label: buttonLabel,
                color: hasAudio ? _primary : const Color(0xFFD1D5DB),
                onTap: hasAudio ? onStart : null,
              ),
          if (state == AnalysisState.loading) ...[
            Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: progressValue > 0 ? progressValue : null,
                    backgroundColor: const Color(0xFFE5E7EB),
                    valueColor: const AlwaysStoppedAnimation(_primary),
                    minHeight: 44,
                  ),
                ),
                Text(
                  progressValue > 0
                      ? '${(progressValue * 100).toInt()}%'
                      : '분석 준비 중...',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: '취소',
              color: const Color(0xFFD1D5DB),
              onTap: onCancel,
            ),
          ],
          if (state == AnalysisState.done) ...[
            Container(
              width: double.infinity,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(
                child: Text(
                  '분석 완료 ✓',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _ActionButton(label: '결과 보기', color: _primary, onTap: onResult),
          ],
        ],
      ),
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
        height: 44,
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
