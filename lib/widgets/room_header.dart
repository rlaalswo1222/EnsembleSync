import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// 방 코드와 참가자 목록.
///
/// 누가 들어와도 화면이 조용해서 알아채기가 어려웠다. 동그라미가 하나
/// 늘어날 뿐인데, 보고 있지 않으면 그냥 지나간다. 합주는 사람이 모여야
/// 시작되니 이건 알려줄 값어치가 있다.
class RoomHeader extends StatefulWidget {
  final String roomCode;
  final List<String> participantNames;
  final VoidCallback onShareRoom;

  const RoomHeader({
    super.key,
    required this.roomCode,
    required this.participantNames,
    required this.onShareRoom,
  });

  @override
  State<RoomHeader> createState() => _RoomHeaderState();
}

class _RoomHeaderState extends State<RoomHeader> {
  static const _primary = AppColors.ink;

  /// 이미 화면에 있던 사람들.
  ///
  /// 처음 방에 들어왔을 때 이미 있던 사람들까지 하나씩 튀어나오면 산만하다.
  /// 그건 '새로 온 것'이 아니라 '원래 있던 것'이므로 조용히 그린다.
  Set<String> _seen = <String>{};

  /// 이번에 새로 들어온 사람들. 이 사람들만 애니메이션을 준다.
  Set<String> _arriving = <String>{};

  @override
  void initState() {
    super.initState();
    _seen = widget.participantNames.toSet();
  }

  @override
  void didUpdateWidget(RoomHeader old) {
    super.didUpdateWidget(old);
    final Set<String> now = widget.participantNames.toSet();
    final Set<String> added = now.difference(_seen);
    if (added.isNotEmpty) {
      setState(() => _arriving = added);
    }
    // 나갔다가 다시 들어오면 그때도 알려주는 것이 맞다.
    _seen = now;
  }

  /// 이름에서 색을 정한다.
  ///
  /// 예전에는 목록의 순서로 골랐다. 그래서 누가 나가면 뒤에 있던 사람들의
  /// 색이 전부 한 칸씩 밀렸다. 애니메이션을 붙이면 그 순간이 그대로 눈에
  /// 띈다. 이름으로 고르면 누가 드나들든 자기 색을 지킨다.
  static Color _colorFor(String name) {
    int hash = 0;
    for (final int unit in name.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return AppColors.avatar[hash % AppColors.avatar.length];
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: _codeRow()),
          const SizedBox(height: 8),
          Row(children: _peopleRow()),
        ],
      ),
    );
  }

  List<Widget> _codeRow() {
    return <Widget>[
      const Text('방 코드',
          style: TextStyle(fontSize: 12, color: AppColors.inkSecondary)),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.fill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          widget.roomCode,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: _primary,
            letterSpacing: 1.5,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Tooltip(
        message: '방 코드 공유',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onShareRoom,
          child: const Icon(Icons.share_rounded,
              size: 16, color: AppColors.inkTertiary),
        ),
      ),
    ];
  }

  List<Widget> _peopleRow() {
    return <Widget>[
      // 숫자가 바뀌는 것도 신호다. 슬쩍 올라오며 바뀐다.
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.4),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: Text(
          '참가자 ${widget.participantNames.length}명',
          key: ValueKey<int>(widget.participantNames.length),
          style:
              const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
        ),
      ),
      const SizedBox(width: 8),
      // 사람이 늘면 줄의 폭이 늘어난다. 툭 늘어나지 않도록 한다.
      AnimatedSize(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final String name in widget.participantNames)
              _Avatar(
                // 이름을 열쇠로 준다. 앞사람이 나가도 남은 사람의
                // 위젯이 그대로 따라가서 색과 상태가 흔들리지 않는다.
                key: ValueKey<String>(name),
                name: name,
                color: _colorFor(name),
                arriving: _arriving.contains(name),
              ),
          ],
        ),
      ),
    ];
  }
}

/// 참가자 한 명.
///
/// 새로 들어온 사람은 살짝 커지며 나타나고, 둘레에 고리가 한 번 퍼졌다
/// 사라진다. 눈길이 가되 계속 움직이지는 않는 정도로 둔다 — 악보를 보는
/// 화면이라 위쪽이 계속 꿈틀대면 방해가 된다.
class _Avatar extends StatefulWidget {
  final String name;
  final Color color;
  final bool arriving;

  const _Avatar({
    super.key,
    required this.name,
    required this.color,
    required this.arriving,
  });

  @override
  State<_Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<_Avatar> with SingleTickerProviderStateMixin {
  static const double _size = 28;

  /// 고리가 퍼져나가는 끝 크기.
  static const double _ringMax = 46;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void initState() {
    super.initState();
    if (widget.arriving) {
      _controller.forward();
    } else {
      // 원래 있던 사람은 완성된 모습으로 둔다.
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String initial =
        widget.name.isNotEmpty ? widget.name.substring(0, 1) : '?';

    // 동그라미는 앞쪽 절반 동안 커지고, 고리는 그동안 계속 퍼진다.
    final Animation<double> pop = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.55, curve: Curves.easeOutBack),
    );
    final Animation<double> ring = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: SizedBox(
        width: _size,
        height: _size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: <Widget>[
                // 퍼지는 고리. 다 퍼지고 나면 사라지므로 자리를 차지하지
                // 않도록 Stack 밖으로 나가게 둔다.
                if (_controller.isAnimating)
                  IgnorePointer(
                    child: Container(
                      width: _size + (_ringMax - _size) * ring.value,
                      height: _size + (_ringMax - _size) * ring.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: widget.color
                              .withValues(alpha: 0.45 * (1 - ring.value)),
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                Transform.scale(
                  scale: 0.4 + 0.6 * pop.value.clamp(0.0, 1.4),
                  child: Opacity(
                    opacity: pop.value.clamp(0.0, 1.0),
                    child: child,
                  ),
                ),
              ],
            );
          },
          child: Container(
            width: _size,
            height: _size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                initial,
                style: const TextStyle(
                  color: AppColors.onAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
