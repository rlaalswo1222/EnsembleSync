import 'package:flutter/material.dart';

import '../models/track_analysis.dart';

/// 코드 진행. 현재 코드를 왼쪽 1/3 지점에 두고 다음 코드들이 오른쪽에 이어진다.
///
/// 지금 치고 있는 코드보다 다음에 올 코드가 더 쓸모 있다. 연주자는 이미
/// 현재 코드를 알고 있기 때문이다. 그래서 앞쪽은 2개만 남기고 뒤를 넓게 준다.
class ChordTimeline extends StatelessWidget {
  const ChordTimeline({
    super.key,
    required this.chords,
    required this.seconds,
    this.primary = const Color(0xFF0F766E),
  });

  final List<ChordSegment> chords;
  final double seconds;
  final Color primary;

  /// 현재 코드 앞뒤로 보여줄 개수.
  static const int _before = 2;
  static const int _after = 3;

  /// 지속 시간을 폭으로 옮길 때의 한계. 이 범위를 벗어나면 글자가 잘리거나
  /// 한 코드가 화면을 다 먹는다.
  static const double _minWidth = 52;
  static const double _maxWidth = 108;
  static const double _widthPerSecond = 22;

  @override
  Widget build(BuildContext context) {
    // 무음 구간은 칩으로 만들지 않는다. 화면에 'N' 이 뜨면 코드로 오해한다.
    final List<ChordSegment> visible =
        chords.where((ChordSegment c) => !c.isSilence).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final int current = _currentIndex(visible);
    final int from = (current - _before).clamp(0, visible.length);
    final int to = (current + _after + 1).clamp(0, visible.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 6),
          child: Text(
            '코드',
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: to - from,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int i) {
              final int index = from + i;
              return _ChordChip(
                chord: visible[index],
                state: index == current
                    ? _ChipState.current
                    : (index < current ? _ChipState.past : _ChipState.upcoming),
                primary: primary,
                width: _widthFor(visible[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  double _widthFor(ChordSegment c) =>
      (c.duration * _widthPerSecond).clamp(_minWidth, _maxWidth);

  /// 현재 시각이 무음 구간에 걸려 있으면 마지막으로 지난 코드를 현재로 본다.
  /// 그래야 무음마다 타임라인이 앞으로 튀지 않는다.
  int _currentIndex(List<ChordSegment> visible) {
    int last = 0;
    for (int i = 0; i < visible.length; i++) {
      if (seconds >= visible[i].time && seconds < visible[i].end) return i;
      if (visible[i].time <= seconds) last = i;
    }
    return last;
  }
}

enum _ChipState { past, current, upcoming }

class _ChordChip extends StatelessWidget {
  const _ChordChip({
    required this.chord,
    required this.state,
    required this.primary,
    required this.width,
  });

  final ChordSegment chord;
  final _ChipState state;
  final Color primary;
  final double width;

  @override
  Widget build(BuildContext context) {
    final bool isCurrent = state == _ChipState.current;
    final bool isPast = state == _ChipState.past;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: width,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isCurrent ? primary : Colors.white,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: isCurrent
              ? primary
              : (isPast ? const Color(0xFFF3F4F6) : const Color(0xFFE5E7EB)),
        ),
      ),
      child: Text(
        chord.label,
        style: TextStyle(
          fontSize: isCurrent ? 20 : 16,
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
          color: isCurrent
              ? Colors.white
              : (isPast ? const Color(0xFFD1D5DB) : const Color(0xFF374151)),
        ),
      ),
    );
  }
}
