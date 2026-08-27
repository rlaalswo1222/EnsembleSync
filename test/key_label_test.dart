import 'package:ensemble_sync/models/track_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

/// 화면에 크게 뜨는 조성 표기.
///
/// 'B' 와 'Bm' 은 다른 조다. 연주자에게는 그 차이가 전부라서, 단조를
/// 장조처럼 보이게 두면 안 된다. 다만 확신이 없을 때 못박아도 안 된다.
KeyEstimate key(String tonic, String mode, double confidence) => KeyEstimate(
      tonic: tonic,
      mode: mode,
      label: '$tonic ${mode == 'minor' ? 'Minor' : 'Major'}',
      confidence: confidence,
    );

void main() {
  const double sure = 0.4;
  const double unsure = 0.05; // ambiguousBelow(0.12) 아래

  test('단조라고 확신하면 m 을 붙인다', () {
    expect(key('B', 'minor', sure).short(), 'Bm');
    expect(key('F#', 'minor', sure).short(), 'F#m');
  });

  test('장조에는 안 붙인다', () {
    expect(key('C', 'major', sure).short(), 'C');
    expect(key('A', 'major', sure).short(), 'A');
  });

  test('확신이 없으면 붙이지 않는다', () {
    // 나란한조는 구성음이 같아 기계가 자주 헷갈린다. 그때 Bm 이라고
    // 못박으면 틀린 확신을 주게 된다. 아래 줄에 두 후보를 함께 띄운다.
    expect(key('B', 'minor', unsure).short(), 'B');
    expect(key('B', 'minor', unsure).relativeLabel, 'D Major');
  });

  test('키를 올려도 단조는 단조다', () {
    final k = key('B', 'minor', sure);
    expect(k.short(semitones: 2), 'C#m');
    expect(k.short(semitones: -1), 'A#m');
  });

  test('한 바퀴 돌아도 제자리', () {
    expect(key('C', 'minor', sure).short(semitones: 12), 'Cm');
    expect(key('C', 'minor', sure).short(semitones: -12), 'Cm');
  });

  test('조성을 못 찾았으면 아무것도 안 준다', () {
    const none = KeyEstimate(
        tonic: null, mode: null, label: 'unknown', confidence: 0);
    expect(none.short(), isNull);
  });
}
