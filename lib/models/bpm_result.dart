// ── BPM 분석 결과 모델 ────────────────────────────────────────
class BpmResult {
  final String jobId;
  final double baseBpm;
  final double avgBpm;
  final double maxBpm;
  final double minBpm;
  final List<BpmPoint> bpmData;
  final List<DeviationSection> deviationSections;

  const BpmResult({
    required this.jobId,
    required this.baseBpm,
    required this.avgBpm,
    required this.maxBpm,
    required this.minBpm,
    required this.bpmData,
    required this.deviationSections,
  });

  factory BpmResult.fromJson(Map<String, dynamic> json) {
    return BpmResult(
      jobId: json['job_id'] as String? ?? '',
      baseBpm: (json['base_bpm'] as num?)?.toDouble() ?? 0,
      avgBpm: (json['avg_bpm'] as num?)?.toDouble() ?? 0,
      maxBpm: (json['max_bpm'] as num?)?.toDouble() ?? 0,
      minBpm: (json['min_bpm'] as num?)?.toDouble() ?? 0,
      bpmData: (json['bpm_data'] as List<dynamic>? ?? [])
          .map((e) => BpmPoint.fromJson(e as Map<String, dynamic>))
          .toList(),
      deviationSections: (json['deviation_sections'] as List<dynamic>? ?? [])
          .map((e) => DeviationSection.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class BpmPoint {
  final double time;
  final double bpm;
  const BpmPoint({required this.time, required this.bpm});

  factory BpmPoint.fromJson(Map<String, dynamic> json) => BpmPoint(
        time: (json['time'] as num).toDouble(),
        bpm: (json['bpm'] as num).toDouble(),
      );
}

class DeviationSection {
  final double start;
  final double end;
  final double bpm;

  const DeviationSection({
    required this.start,
    required this.end,
    required this.bpm,
  });

  factory DeviationSection.fromJson(Map<String, dynamic> json) => DeviationSection(
        start: (json['start'] as num).toDouble(),
        end: (json['end'] as num).toDouble(),
        bpm: (json['bpm'] as num).toDouble(),
      );

  // 기준 BPM 대비 변화량
  double deviation(double baseBpm) => bpm - baseBpm;

  // 빨라짐/느려짐 여부
  bool isFaster(double baseBpm) => bpm > baseBpm;

  // mm:ss 포맷
  String get startLabel => _format(start);
  String get endLabel => _format(end);

  String _format(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(1, '0');
    final s = (seconds % 60).toInt().toString().padLeft(2, '0');
    return '$m:$s';
  }
}