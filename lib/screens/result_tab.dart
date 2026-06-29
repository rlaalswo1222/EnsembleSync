import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/bpm_result.dart';
import '../models/track_result.dart';
import '../services/api_service.dart';
import '../widgets/bpm_result_view.dart';
import '../widgets/track_result_view.dart';

enum ResultMode { bpm, track, empty }

class ResultTab extends StatefulWidget {
  final List<TrackResult> tracks;
  final String? audioFilename;
  final Uint8List? audioBytes;
  final String? bpmJobId;
  final BpmResult? bpmResult;
  final ResultMode? preferredMode;

  const ResultTab({
    super.key,
    required this.tracks,
    this.audioFilename,
    this.audioBytes,
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
    if (widget.preferredMode == ResultMode.track && widget.tracks.isNotEmpty) {
      return ResultMode.track;
    }
    if (widget.preferredMode == ResultMode.bpm && _bpmResult != null) {
      return ResultMode.bpm;
    }
    if (_bpmResult != null) {
      return ResultMode.bpm;
    }
    if (widget.tracks.isNotEmpty) {
      return ResultMode.track;
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
        child: CircularProgressIndicator(color: Color(0xFF8B5CF6)),
      );
    }

    switch (_mode) {
      case ResultMode.bpm:
        return BpmResultView(
          result: _bpmResult!,
          audioFilename: widget.audioFilename,
          audioBytes: widget.audioBytes,
        );
      case ResultMode.track:
        return TrackResultView(
          tracks: widget.tracks,
          audioFilename: widget.audioFilename,
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
            color: Color(0xFFD1D5DB),
          ),
          SizedBox(height: 16),
          Text(
            '분석 후 결과가 표시됩니다',
            style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }
}
