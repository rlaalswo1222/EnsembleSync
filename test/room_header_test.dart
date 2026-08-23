import 'package:ensemble_sync/widgets/room_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child, Size size) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
      ),
    );
  }

  RoomHeader header({
    List<String> names = const <String>['가람', '나루'],
  }) {
    return RoomHeader(
      roomCode: 'AB12CD',
      participantNames: names,
      onShareRoom: () {},
    );
  }

  testWidgets('아바타 색은 목록 순서가 아니라 이름을 따른다',
      (WidgetTester tester) async {
    Color colorOf(String initial) {
      final Container c = tester.widget<Container>(
        find
            .ancestor(
              of: find.text(initial),
              matching: find.byType(Container),
            )
            .first,
      );
      return (c.decoration! as BoxDecoration).color!;
    }

    await tester.pumpWidget(
      wrap(header(names: const <String>['가람', '나루']), const Size(400, 800)),
    );
    await tester.pumpAndSettle();
    final Color garamFirst = colorOf('가');

    // 순서를 뒤집어 다시 그린다. 다른 기기에서는 참가자 순서가 다르게
    // 온다 — 그때마다 색이 밀리면 같은 사람을 알아볼 수 없다.
    await tester.pumpWidget(
      wrap(header(names: const <String>['나루', '가람']), const Size(400, 800)),
    );
    await tester.pumpAndSettle();

    expect(colorOf('가'), garamFirst,
        reason: '같은 사람은 어느 기기에서든 같은 색이어야 한다');
  });

  testWidgets('새로 들어온 사람만 나타나는 효과를 받는다',
      (WidgetTester tester) async {
    // 나타나는 동안에만 둘레에 고리가 하나 그려진다. 그 고리의 개수로
    // 지금 누가 움직이고 있는지를 센다.
    int rings() => tester.widgetList(find.byType(IgnorePointer)).length;

    await tester.pumpWidget(
      wrap(header(names: const <String>['가람']), const Size(400, 800)),
    );
    await tester.pumpAndSettle();
    final int atRest = rings();

    // 한 명이 들어온다.
    await tester.pumpWidget(
      wrap(header(names: const <String>['가람', '나루']), const Size(400, 800)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(rings(), atRest + 1,
        reason: '새로 온 사람 하나만 움직여야 한다. 원래 있던 사람까지 '
            '튀어나오면 산만하다');

    // 끝나면 다시 조용해진다.
    await tester.pumpAndSettle();
    expect(rings(), atRest);
  });
}
