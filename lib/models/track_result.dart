import 'package:flutter/material.dart';

class TrackResult {
  final String label;
  final String url;
  final IconData icon;

  const TrackResult({
    required this.label,
    required this.url,
    required this.icon,
  });
}

class TrackResultFactory {
  static const _metadata = {
    'vocals': _TrackMetadata('보컬', Icons.music_note_rounded),
    'drums': _TrackMetadata('드럼', Icons.graphic_eq_rounded),
    'bass': _TrackMetadata('베이스', Icons.bar_chart_rounded),
    'other': _TrackMetadata('기타', Icons.queue_music_rounded),
  };

  static List<TrackResult> fromSeparatedTracks(
      Map<String, dynamic> tracksJson) {
    return _metadata.entries
        .where((entry) => tracksJson[entry.key] != null)
        .map(
          (entry) => TrackResult(
            label: entry.value.label,
            url: tracksJson[entry.key] as String,
            icon: entry.value.icon,
          ),
        )
        .toList();
  }
}

class _TrackMetadata {
  final String label;
  final IconData icon;

  const _TrackMetadata(this.label, this.icon);
}
