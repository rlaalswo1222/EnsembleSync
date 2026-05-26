import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';

// ── 분석 상태 ─────────────────────────────────────────────────
enum AnalysisState { idle, loading, done }

// ── 트랙 결과 모델 ────────────────────────────────────────────
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
  final VoidCallback onGoToResult; // 결과 탭으로 이동

  const AnalysisTab({
    super.key,
    required this.roomId,
    required this.roomCode,
    required this.ws,
    required this.onGoToResult,
  });

  @override
  State<AnalysisTab> createState() => _AnalysisTabState();
}

class _AnalysisTabState extends State<AnalysisTab> {
  static const _purple = Color(0xFF8B5CF6);

  // ── 업로드된 음원 파일 ────────────────────────────────────
  Uint8List? _audioBytes;
  String? _audioFilename;

  // ── 각 분석 상태 ──────────────────────────────────────────
  AnalysisState _bpmState = AnalysisState.idle;
  AnalysisState _pitchState = AnalysisState.idle;
  AnalysisState _trackState = AnalysisState.idle;

  // ── 트랙 분리 결과 ────────────────────────────────────────
  List<TrackResult> _tracks = [];
  double _trackProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _listenWs();
  }

  // ── WebSocket 트랙 분리 완료 알림 수신 ───────────────────
  void _listenWs() {
    widget.ws.events.listen((event) {
      if (event.type == WsEventType.trackSeparated) {
        final payload = event.data['payload'] as Map<String, dynamic>? ?? {};
        final tracksJson = payload['tracks'] as Map<String, dynamic>? ?? {};
        final results = <TrackResult>[
          if (tracksJson['vocals'] != null)
            TrackResult(label: '보컬', url: tracksJson['vocals'] as String, icon: Icons.music_note_rounded),
          if (tracksJson['drums'] != null)
            TrackResult(label: '드럼', url: tracksJson['drums'] as String, icon: Icons.graphic_eq_rounded),
          if (tracksJson['bass'] != null)
            TrackResult(label: '베이스', url: tracksJson['bass'] as String, icon: Icons.bar_chart_rounded),
          if (tracksJson['guitar'] != null)
            TrackResult(label: '기타', url: tracksJson['guitar'] as String, icon: Icons.queue_music_rounded),
        ];
        if (mounted) {
          setState(() {
            _trackState = AnalysisState.done;
            _trackProgress = 1.0;
            _tracks = results;
          });
        }
      } else if (event.type == WsEventType.separationProgress) {
        final progress = (event.data['progress'] as num?)?.toDouble() ?? 0;
        if (mounted) setState(() => _trackProgress = progress / 100.0);
      }
    });
  }

  // ── 음원 파일 선택 ────────────────────────────────────────
  Future<void> _pickAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'flac', 'm4a'],
    );
    if (result != null && result.files.first.bytes != null) {
      setState(() {
        _audioBytes = result.files.first.bytes;
        _audioFilename = result.files.first.name;
        // 새 파일 선택 시 분석 상태 초기화
        _bpmState = AnalysisState.idle;
        _pitchState = AnalysisState.idle;
        _trackState = AnalysisState.idle;
        _tracks = [];
      });
    }
  }

  // ── BPM 분석 시작 ─────────────────────────────────────────
  Future<void> _startBpm() async {
    if (_audioBytes == null) return;
    setState(() => _bpmState = AnalysisState.loading);
    try {
      await ApiService().uploadAudio(
        roomId: widget.roomId,
        bytes: _audioBytes!,
        filename: _audioFilename!,
        purpose: 'bpm',
      );
      if (mounted) setState(() => _bpmState = AnalysisState.done);
    } catch (e) {
      if (mounted) {
        setState(() => _bpmState = AnalysisState.idle);
        _showError('BPM 분석 실패: $e');
      }
    }
  }

  // ── 피치 분석 시작 ────────────────────────────────────────
  Future<void> _startPitch() async {
    if (_audioBytes == null) return;
    setState(() => _pitchState = AnalysisState.loading);
    try {
      await ApiService().uploadAudio(
        roomId: widget.roomId,
        bytes: _audioBytes!,
        filename: _audioFilename!,
        purpose: 'pitch',
      );
      if (mounted) setState(() => _pitchState = AnalysisState.done);
    } catch (e) {
      if (mounted) {
        setState(() => _pitchState = AnalysisState.idle);
        _showError('피치 분석 실패: $e');
      }
    }
  }

  // ── 트랙 분리 시작 ────────────────────────────────────────
  Future<void> _startTrack() async {
    if (_audioBytes == null) return;
    setState(() => _trackState = AnalysisState.loading);
    try {
      await ApiService().requestTrackSeparation(
        roomId: widget.roomId,
        bytes: _audioBytes!,
        filename: _audioFilename!,
      );
      // 완료는 WebSocket으로 수신 (_listenWs)
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
          // ── 음원 파일 업로드 영역 ──────────────────────────
          _buildAudioUploadArea(),
          const SizedBox(height: 12),

          // ── BPM 분석 카드 ──────────────────────────────────
          _buildAnalysisCard(
            icon: Icons.graphic_eq_rounded,
            title: 'BPM 분석',
            subtitle: '구간별 템포 이탈을 확인하세요',
            state: _bpmState,
            onStart: _startBpm,
            onResult: widget.onGoToResult,
          ),
          const SizedBox(height: 12),

          // ── 피치 분석 카드 ─────────────────────────────────
          _buildAnalysisCard(
            icon: Icons.music_note_rounded,
            title: '피치 분석',
            subtitle: '보컬 음정 이탈 구간을 확인하세요',
            state: _pitchState,
            onStart: _startPitch,
            onResult: widget.onGoToResult,
          ),
          const SizedBox(height: 12),

          // ── 트랙 분리 카드 ─────────────────────────────────
          _buildAnalysisCard(
            icon: Icons.content_cut_rounded,
            title: '트랙 분리',
            subtitle: '보컬/드럼/베이스/기타를 분리합니다',
            state: _trackState,
            onStart: _startTrack,
            onResult: widget.onGoToResult,
            buttonLabel: '분리 시작',
            progressValue: _trackProgress,
          ),
        ],
      ),
    );
  }

  // ── 음원 업로드 영역 ──────────────────────────────────────
  Widget _buildAudioUploadArea() {
    if (_audioBytes == null) {
      // 파일 미선택
      return GestureDetector(
        onTap: _pickAudio,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFFD1D5DB),
              style: BorderStyle.solid,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
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

    // 파일 선택됨
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
            onTap: () => setState(() {
              _audioBytes = null;
              _audioFilename = null;
              _bpmState = AnalysisState.idle;
              _pitchState = AnalysisState.idle;
              _trackState = AnalysisState.idle;
              _tracks = [];
            }),
            child: const Icon(Icons.close_rounded,
                size: 18, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }

  // ── 분석 카드 ─────────────────────────────────────────────
  Widget _buildAnalysisCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required AnalysisState state,
    required VoidCallback onStart,
    required VoidCallback onResult,
    String buttonLabel = '분석 시작',
    double progressValue = 0.0,
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
          // 아이콘 + 제목
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F0FF),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: _purple, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6B7280))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 상태별 버튼
          if (state == AnalysisState.idle)
            _ActionButton(
              label: buttonLabel,
              enabled: hasFile,
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
                    valueColor: AlwaysStoppedAnimation(_purple),
                    minHeight: 44,
                  ),
                ),
                if (progressValue > 0)
                  Text(
                    '${(progressValue * 100).toInt()}%',
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
              onTap: () => setState(() => _trackState = AnalysisState.idle),
            ),
          ],

          if (state == AnalysisState.done) ...[
            // 완료 버튼
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
                      fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _ActionButton(
              label: '결과 보기',
              color: _purple,
              onTap: onResult,
            ),
          ],
        ],
      ),
    );
  }
}

// ── 버튼 위젯 ─────────────────────────────────────────────────
class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool enabled;

  const _ActionButton({
    required this.label,
    required this.color,
    this.onTap,
    this.enabled = true,
  });

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