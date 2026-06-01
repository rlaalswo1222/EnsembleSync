import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';

enum AnalysisState { idle, loading, done }

class TrackResult {
  final String label;
  final String url;
  final IconData icon;
  TrackResult({required this.label, required this.url, required this.icon});
}

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
  static const _purple = Color(0xFF8B5CF6);

  Uint8List? _audioBytes;
  String? _audioFilename;

  AnalysisState _bpmState = AnalysisState.idle;
  AnalysisState _pitchState = AnalysisState.idle;
  AnalysisState _trackState = AnalysisState.idle;

  double _trackProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _listenWs();
  }

  void _listenWs() {
    widget.ws.events.listen((event) {
      if (event.type == WsEventType.bpmAnalyzed) {
        final jobId = event.data['job_id'] as String?;
        if (jobId != null) widget.onBpmJobId?.call(jobId);
        if (mounted) {
          setState(() => _bpmState = AnalysisState.done);
          widget.onGoToResult();
        }
      } else if (event.type == WsEventType.trackSeparated) {
        if (mounted) {
          setState(() {
            _trackState = AnalysisState.done;
            _trackProgress = 1.0;
          });
        }
      } else if (event.type == WsEventType.separationProgress) {
        final progress = (event.data['progress'] as num?)?.toDouble() ?? 0;
        if (mounted) setState(() => _trackProgress = progress / 100.0);
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
        _bpmState = AnalysisState.idle;
        _pitchState = AnalysisState.idle;
        _trackState = AnalysisState.idle;
      });
      widget.onAudioPicked?.call(bytes, filename);
    }
  }

  Future<void> _startBpm() async {
    if (_audioBytes == null) return;
    setState(() => _bpmState = AnalysisState.loading);
    try {
      final uploadResult = await ApiService().uploadAudio(
        roomId: widget.roomId,
        bytes: _audioBytes!,
        filename: _audioFilename!,
        purpose: 'bpm',
      );
      final audioFileId = uploadResult['audio_file_id'] as String;
      await ApiService().startBpmAnalysis(
        roomId: widget.roomId,
        audioFileId: audioFileId,
      );
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
        title: const Text('미구현 기능',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: const Text(
          '피치 분석 기능은 현재 개발 중입니다.\n추후 업데이트를 통해 제공될 예정입니다.',
          style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인',
                style: TextStyle(color: Color(0xFF8B5CF6), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Future<void> _startTrack() async {
    if (_audioBytes == null) return;
    setState(() => _trackState = AnalysisState.loading);
    try {
      await ApiService().requestTrackSeparation(
        roomId: widget.roomId,
        bytes: _audioBytes!,
        filename: _audioFilename!,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _trackState = AnalysisState.idle);
        _showError('트랙 분리 요청 실패: $e');
      }
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
            buttonLabel: '분리 시작',
            progressValue: _trackProgress,
          ),
          const SizedBox(height: 12),
          _buildAnalysisCard(
            icon: Icons.graphic_eq_rounded,
            title: 'BPM 분석',
            subtitle: '구간별 템포 이탈을 확인하세요',
            state: _bpmState,
            onStart: _startBpm,
            onResult: widget.onGoToResult,
            enabled: _trackState == AnalysisState.done,
          ),
          const SizedBox(height: 12),
          _buildAnalysisCard(
            icon: Icons.music_note_rounded,
            title: '피치 분석',
            subtitle: '보컬 음정 이탈 구간을 확인하세요',
            state: _pitchState,
            onStart: _startPitch,
            onResult: widget.onGoToResult,
            enabled: _trackState == AnalysisState.done,
          ),
        ],
      ),
    );
  }

  Widget _buildAudioUploadArea() {
    if (_audioBytes == null) {
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
              Text('음원 파일 업로드 (MP3, WAV)',
                  style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F0FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.audio_file_rounded, color: _purple, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_audioFilename ?? '',
                style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E), fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis),
          ),
          GestureDetector(
            onTap: () => setState(() {
              _audioBytes = null;
              _audioFilename = null;
              _bpmState = AnalysisState.idle;
              _pitchState = AnalysisState.idle;
              _trackState = AnalysisState.idle;
            }),
            child: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF9CA3AF)),
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
    String buttonLabel = '분석 시작',
    double progressValue = 0.0,
    bool enabled = true,
  }) {
    final hasFile = _audioBytes != null;

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
                width: 40, height: 40,
                decoration: const BoxDecoration(
                  color: Color(0xFFF3F0FF), shape: BoxShape.circle),
                child: Icon(icon, color: _purple, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                ],
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
                color: hasFile ? _purple : const Color(0xFFD1D5DB),
                onTap: hasFile ? onStart : null,
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
                    valueColor: const AlwaysStoppedAnimation(_purple),
                    minHeight: 44,
                  ),
                ),
                if (progressValue > 0)
                  Text('${(progressValue * 100).toInt()}%',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: '취소',
              color: const Color(0xFFD1D5DB),
              onTap: () => setState(() => _trackState = AnalysisState.idle),
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
                child: Text('분석 완료 ✓',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
              ),
            ),
            const SizedBox(height: 8),
            _ActionButton(label: '결과 보기', color: _purple, onTap: onResult),
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
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        child: Center(
          child: Text(label,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
        ),
      ),
    );
  }
}
