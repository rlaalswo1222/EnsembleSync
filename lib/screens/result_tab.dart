import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import 'analysis_tab.dart';

class ResultTab extends StatelessWidget {
  final List<TrackResult> tracks;
  final String? audioFilename;

  const ResultTab({
    super.key,
    required this.tracks,
    this.audioFilename,
  });

  static const _purple = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.hourglass_empty_rounded,
                size: 48, color: Color(0xFFD1D5DB)),
            SizedBox(height: 16),
            Text(
              '분석 후 결과가 표시됩니다',
              style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '트랙 분리 결과',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (audioFilename != null) ...[
            const SizedBox(height: 4),
            Text(
              audioFilename!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
          ],
          const SizedBox(height: 16),
          ...tracks.map((track) => _buildTrackCard(context, track)),
        ],
      ),
    );
  }

  Widget _buildTrackCard(BuildContext context, TrackResult track) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F7FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          // 아이콘
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: Color(0xFFEDE9FE),
              shape: BoxShape.circle,
            ),
            child: Icon(track.icon, color: _purple, size: 18),
          ),
          const SizedBox(width: 12),

          // 트랙 이름
          Expanded(
            child: Text(
              track.label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          // 재생 버튼
          GestureDetector(
            onTap: () => _playTrack(context, track.url),
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: _purple,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 10),

          // 다운로드 버튼
          GestureDetector(
            onTap: () => _downloadTrack(context, track.url),
            child: const Icon(Icons.download_rounded,
                color: Color(0xFF6B7280), size: 24),
          ),
        ],
      ),
    );
  }

  Future<void> _playTrack(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('재생할 수 없습니다')),
      );
    }
  }

  Future<void> _downloadTrack(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('다운로드할 수 없습니다')),
      );
    }
  }
}