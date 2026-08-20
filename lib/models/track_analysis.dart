import 'dart:convert';

/// 서버가 분리 직후 만들어 두는 /uploads/separated/{job_id}/analysis.json 을
/// 그대로 받아 담는다. 파형 피크, 조성, 코드 진행이 들어 있다.
///
/// 이 파일이 없는 경우도 정상이다. 분석 기능이 들어가기 전에 분리한 곡이거나
/// 분석만 실패한 경우인데, 그때도 재생과 믹싱은 되어야 한다.
class TrackAnalysis {
  const TrackAnalysis({
    required this.duration,
    required this.peaksPerSecond,
    required this.peakScale,
    required this.peaks,
    required this.chords,
    this.key,
  });

  /// 초 단위 전체 길이.
  final double duration;

  /// 피크 배열의 초당 개수. 피크 인덱스를 시간으로 되돌릴 때 쓴다.
  final int peaksPerSecond;

  /// 피크 값의 최댓값. 서버가 0~255 정수로 보내므로 보통 255다.
  final int peakScale;

  /// 스템 이름(vocals/drums/bass/other) 별 파형 피크.
  final Map<String, List<int>> peaks;

  final List<ChordSegment> chords;

  final KeyEstimate? key;

  static TrackAnalysis? tryParse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      return TrackAnalysis.fromJson(json);
    } catch (_) {
      // 분석 결과는 부가 정보다. 깨져 있어도 재생을 막지 않는다.
      return null;
    }
  }

  factory TrackAnalysis.fromJson(Map<String, dynamic> json) {
    final rawPeaks = json['peaks'] as Map<String, dynamic>? ?? const {};
    final rawChords = json['chords'] as List<dynamic>? ?? const [];

    return TrackAnalysis(
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      peaksPerSecond: (json['peaks_per_second'] as num?)?.toInt() ?? 20,
      peakScale: (json['peak_scale'] as num?)?.toInt() ?? 255,
      peaks: <String, List<int>>{
        for (final MapEntry<String, dynamic> e in rawPeaks.entries)
          e.key: <int>[
            for (final dynamic v in e.value as List<dynamic>)
              (v as num).toInt(),
          ],
      },
      chords: <ChordSegment>[
        for (final dynamic c in rawChords)
          ChordSegment.fromJson(c as Map<String, dynamic>),
      ],
      key: json['key'] is Map<String, dynamic>
          ? KeyEstimate.fromJson(json['key'] as Map<String, dynamic>)
          : null,
    );
  }

  /// 코드가 하나도 없거나 전부 무음(N)이면 타임라인을 띄울 이유가 없다.
  bool get hasChords => chords.any((ChordSegment c) => c.label != 'N');

  /// [seconds] 시점에 울리는 코드의 인덱스. 없으면 -1.
  int chordIndexAt(double seconds) {
    for (int i = 0; i < chords.length; i++) {
      if (seconds >= chords[i].time && seconds < chords[i].end) return i;
    }
    return -1;
  }
}

class ChordSegment {
  const ChordSegment({
    required this.time,
    required this.end,
    required this.label,
  });

  final double time;
  final double end;

  /// 'Am', 'F#m' 같은 코드 이름. 무음 구간은 'N'.
  final String label;

  double get duration => end - time;

  bool get isSilence => label == 'N';

  factory ChordSegment.fromJson(Map<String, dynamic> json) => ChordSegment(
        time: (json['time'] as num?)?.toDouble() ?? 0,
        end: (json['end'] as num?)?.toDouble() ?? 0,
        label: json['label'] as String? ?? 'N',
      );
}

class KeyEstimate {
  const KeyEstimate({
    required this.tonic,
    required this.mode,
    required this.label,
    required this.confidence,
  });

  /// 'C', 'F#' 같은 으뜸음. 판정 실패 시 null.
  final String? tonic;

  /// 'major' 또는 'minor'.
  final String? mode;

  final String label;

  /// 1위와 2위 조성의 점수 차. 나란한조끼리는 구성음이 같아 원래 작게 나온다.
  final double confidence;

  static const List<String> pitchNames = <String>[
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];

  factory KeyEstimate.fromJson(Map<String, dynamic> json) => KeyEstimate(
        tonic: json['tonic'] as String?,
        mode: json['mode'] as String?,
        label: json['label'] as String? ?? 'unknown',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      );

  bool get isValid => tonic != null && pitchNames.contains(tonic);

  /// 으뜸음을 [semitones] 만큼 올린 표기. 이조 상태를 보여줄 때 쓴다.
  String? transposed(int semitones) {
    if (!isValid) return null;
    final int base = pitchNames.indexOf(tonic!);
    // Dart 의 % 는 음수에서 음수를 돌려주므로 한 번 더 감아준다.
    return pitchNames[((base + semitones) % 12 + 12) % 12];
  }

  /// 나란한조. B단조와 D장조처럼 구성음이 같아 기계 판정이 흔들리는 짝이다.
  /// 신뢰도가 낮을 때 후보를 하나 더 보여주기 위한 것.
  String? get relativeLabel {
    if (!isValid) return null;
    final int base = pitchNames.indexOf(tonic!);
    if (mode == 'minor') {
      return '${pitchNames[(base + 3) % 12]} Major';
    }
    return '${pitchNames[(base + 9) % 12]} Minor';
  }

  /// 이 값 아래면 나란한조와 구분이 어려운 상태로 본다.
  static const double ambiguousBelow = 0.12;

  bool get isAmbiguous => confidence < ambiguousBelow;
}
