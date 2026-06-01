class BpmPoint {
  final double time;
  final double bpm;
  BpmPoint({required this.time, required this.bpm});

  factory BpmPoint.fromJson(Map<String, dynamic> j) => BpmPoint(
        time: (j['time'] as num).toDouble(),
        bpm: (j['bpm'] as num).toDouble(),
      );
}

class DeviationSection {
  final double startTime;
  final double endTime;
  final double avgBpm;

  DeviationSection({
    required this.startTime,
    required this.endTime,
    required this.avgBpm,
  });

  factory DeviationSection.fromJson(Map<String, dynamic> j) => DeviationSection(
        startTime: (j['start_time'] as num).toDouble(),
        endTime: (j['end_time'] as num).toDouble(),
        avgBpm: (j['avg_bpm'] as num).toDouble(),
      );

  String get startLabel => _fmt(startTime);
  String get endLabel => _fmt(endTime);

  double deviation(double baseBpm) => avgBpm - baseBpm;
  bool isFaster(double baseBpm) => avgBpm > baseBpm;

  String _fmt(double secs) {
    final m = (secs ~/ 60).toString().padLeft(1, '0');
    final s = (secs % 60).toInt().toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class BpmResult {
  final double baseBpm;
  final double avgBpm;
  final double maxBpm;
  final double minBpm;
  final List<BpmPoint> bpmData;
  final List<DeviationSection> deviationSections;

  BpmResult({
    required this.baseBpm,
    required this.avgBpm,
    required this.maxBpm,
    required this.minBpm,
    required this.bpmData,
    required this.deviationSections,
  });

  factory BpmResult.fromJson(Map<String, dynamic> j) => BpmResult(
        baseBpm: (j['base_bpm'] as num).toDouble(),
        avgBpm: (j['avg_bpm'] as num).toDouble(),
        maxBpm: (j['max_bpm'] as num).toDouble(),
        minBpm: (j['min_bpm'] as num).toDouble(),
        bpmData: (j['bpm_data'] as List)
            .map((e) => BpmPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        deviationSections: (j['deviation_sections'] as List? ?? [])
            .map((e) => DeviationSection.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
