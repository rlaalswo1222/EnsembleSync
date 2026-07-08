import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/track_result.dart';
import '../services/api_service.dart';

class TrackResultView extends StatefulWidget {
  final List<TrackResult> tracks;
  final String? audioFilename;

  const TrackResultView({
    super.key,
    required this.tracks,
    this.audioFilename,
  });

  @override
  State<TrackResultView> createState() => _TrackResultViewState();
}

class _TrackResultViewState extends State<TrackResultView> {
  static const _primary = Color(0xFF0F766E);

  final _trackPlayer = AudioPlayer();
  Duration _trackPosition = Duration.zero;
  Duration _trackDuration = Duration.zero;
  bool _trackIsPlaying = false;
  String? _playingTrackUrl;
  String? _savingTrackUrl;
  String? _savingTrackMessage;

  double get _trackPlayPosition => _trackDuration.inMilliseconds > 0
      ? _trackPosition.inMilliseconds / _trackDuration.inMilliseconds
      : 0.0;

  @override
  void initState() {
    super.initState();
    _trackPlayer.onPositionChanged.listen((position) {
      if (mounted) setState(() => _trackPosition = position);
    });
    _trackPlayer.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _trackDuration = duration);
    });
    _trackPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _trackIsPlaying = state == PlayerState.playing);
      }
    });
    _trackPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _trackPosition = Duration.zero;
          _trackIsPlaying = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(TrackResultView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_playingTrackUrl == null) return;

    final currentUrlStillExists =
        widget.tracks.any((track) => track.url == _playingTrackUrl);
    if (!currentUrlStillExists) {
      unawaited(_trackPlayer.stop());
      _playingTrackUrl = null;
      _trackPosition = Duration.zero;
      _trackDuration = Duration.zero;
      _trackIsPlaying = false;
    }
  }

  @override
  void dispose() {
    _trackPlayer.dispose();
    super.dispose();
  }

  Future<void> _playTrackAudio(String url) async {
    if (_playingTrackUrl == url) {
      if (_trackIsPlaying) {
        await _trackPlayer.pause();
      } else {
        await _trackPlayer.resume();
      }
    } else {
      await _trackPlayer.stop();
      setState(() {
        _playingTrackUrl = url;
        _trackPosition = Duration.zero;
        _trackDuration = Duration.zero;
      });
      await _trackPlayer.play(UrlSource(url));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('트랙 분리 결과',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (widget.audioFilename != null) ...[
            const SizedBox(height: 4),
            Text(widget.audioFilename!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          ],
          const SizedBox(height: 16),
          ...widget.tracks.map(_buildTrackCard),
        ],
      ),
    );
  }

  Widget _buildTrackCard(TrackResult track) {
    final isActive = _playingTrackUrl == track.url;
    final isPlaying = isActive && _trackIsPlaying;
    final isSaving = _savingTrackUrl == track.url;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDFA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isActive
              ? _primary.withValues(alpha: 0.4)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Color(0xFFCCFBF1),
                  shape: BoxShape.circle,
                ),
                child: Icon(track.icon, color: _primary, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  track.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => _playTrackAudio(track.url),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: _primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: isSaving ? null : () => _downloadTrack(context, track),
                child: isSaving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF6B7280),
                        ),
                      )
                    : const Icon(Icons.download_rounded,
                        color: Color(0xFF6B7280), size: 24),
              ),
            ],
          ),
          if (isSaving && _savingTrackMessage != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _savingTrackMessage!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (isActive) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                      activeTrackColor: _primary,
                      inactiveTrackColor: const Color(0xFFE5E7EB),
                      thumbColor: _primary,
                    ),
                    child: Slider(
                      value: _trackPlayPosition,
                      onChanged: _trackDuration.inMilliseconds > 0
                          ? (value) => _trackPlayer.seek(
                                Duration(
                                  milliseconds:
                                      (value * _trackDuration.inMilliseconds)
                                          .round(),
                                ),
                              )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_formatTime(_trackPosition.inMilliseconds / 1000)} / ${_formatTime(_trackDuration.inMilliseconds / 1000)}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _primary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadTrack(BuildContext context, TrackResult track) async {
    final filename = _trackFilename(track);
    setState(() {
      _savingTrackUrl = track.url;
      _savingTrackMessage = '$filename 다운로드 중...';
    });

    try {
      final bytes = await ApiService().downloadTrack(track.url);
      if (!context.mounted) return;

      setState(() {
        _savingTrackMessage = '$filename 저장 위치 선택 중...';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장할 위치를 선택해주세요.')),
      );

      final extension = _trackExtension(track);
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: '트랙 저장 위치 선택',
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: [extension],
        bytes: bytes,
      );

      if (!context.mounted) return;
      if (savedPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('트랙 저장이 취소되었습니다.')),
        );
      } else {
        setState(() {
          _savingTrackMessage = '$savedPath 에 저장 중...';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 완료: $savedPath')),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('트랙 다운로드 실패: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingTrackUrl = null;
          _savingTrackMessage = null;
        });
      }
    }
  }

  String _trackFilename(TrackResult track) {
    final safeLabel = track.label.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return '${safeLabel}_track.${_trackExtension(track)}';
  }

  String _trackExtension(TrackResult track) {
    final extension =
        Uri.tryParse(track.url)?.pathSegments.last.split('.').last;
    if (extension == null || extension.length > 5) return 'wav';
    return extension.toLowerCase();
  }

  String _formatTime(double seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(1, '0');
    final restSeconds = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$minutes:$restSeconds';
  }
}
