import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/bpm_result.dart';
import '../models/track_result.dart';
import '../services/api_service.dart';
import '../widgets/bpm_result_view.dart';
import '../widgets/mixer_workspace.dart';
import '../theme/tokens.dart';

enum ResultMode { bpm, track, empty }

class ResultTab extends StatefulWidget {
  final List<TrackResult> tracks;
  final String? analysisUrl;
  final bool bpmPending;
  final String? audioFilename;
  final Uint8List? audioBytes;
  final String? audioUrl;
  final String? bpmJobId;
  final BpmResult? bpmResult;
  final ResultMode? preferredMode;

  const ResultTab({
    super.key,
    required this.tracks,
    this.analysisUrl,
    this.bpmPending = false,
    this.audioFilename,
    this.audioBytes,
    this.audioUrl,
    this.bpmJobId,
    this.bpmResult,
    this.preferredMode,
  });

  @override
  State<ResultTab> createState() => _ResultTabState();
}

class _ResultTabState extends State<ResultTab> {
  BpmResult? _bpmResult;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _bpmResult = widget.bpmResult;
    if (_bpmResult == null && widget.bpmJobId != null) {
      _loadBpmResult(widget.bpmJobId!);
    }
  }

  @override
  void didUpdateWidget(ResultTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bpmResult != oldWidget.bpmResult && widget.bpmResult != null) {
      setState(() => _bpmResult = widget.bpmResult);
      return;
    }

    final jobChanged =
        widget.bpmJobId != null && widget.bpmJobId != oldWidget.bpmJobId;
    if (jobChanged) {
      setState(() => _bpmResult = widget.bpmResult);
      if (widget.bpmResult == null) {
        _loadBpmResult(widget.bpmJobId!);
      }
    }
  }

  ResultMode get _mode {
    // 분리 결과가 있으면 언제나 워크스페이스다. BPM 은 그 안의 칸을 눌러서 본다.
    if (widget.tracks.isNotEmpty) {
      return ResultMode.track;
    }
    if (_bpmResult != null) {
      return ResultMode.bpm;
    }
    return ResultMode.empty;
  }

  Future<void> _loadBpmResult(String jobId) async {
    setState(() => _isLoading = true);
    try {
      final data = await ApiService().getBpmResult(jobId);
      if (mounted && widget.bpmJobId == jobId) {
        setState(() => _bpmResult = BpmResult.fromJson(data));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('BPM 결과 조회 실패: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.ink),
      );
    }

    switch (_mode) {
      case ResultMode.bpm:
        return BpmResultView(
          result: _bpmResult!,
          audioFilename: widget.audioFilename,
          audioBytes: widget.audioBytes,
          audioUrl: widget.audioUrl,
        );
      case ResultMode.track:
        return MixerWorkspace(
          // 트랙 목록이 바뀌면 엔진을 처음부터 다시 만든다. 이전 곡의
          // 오디오가 남아 있으면 새 곡과 겹쳐서 재생된다.
          key: ValueKey<String>(
            widget.tracks.map((TrackResult t) => t.url).join('|'),
          ),
          tracks: widget.tracks,
          analysisUrl: widget.analysisUrl,
          bpmResult: _bpmResult,
          bpmPending: widget.bpmPending && _bpmResult == null,
          audioUrl: widget.audioUrl,
        );
      case ResultMode.empty:
        return const _EmptyResultView();
    }
  }
}

class _EmptyResultView extends StatelessWidget {
  const _EmptyResultView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.hourglass_empty_rounded,
            size: 48,
            color: AppColors.inkTertiary,
          ),
          SizedBox(height: 16),
          Text(
            '분석 후 결과가 표시됩니다',
            style: TextStyle(fontSize: 14, color: AppColors.inkTertiary),
          ),
        ],
      ),
    );
  }
}
