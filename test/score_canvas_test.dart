import 'dart:typed_data';

import 'package:ensemble_sync/models/stroke.dart';
import 'package:ensemble_sync/widgets/score_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2:1 짜리 한 점 png. 비율만 재면 되므로 내용은 상관없다.
///
/// ScoreCanvas 는 이 비율로 악보 사각형을 만든다. 그 사각형이 곧 필기
/// 좌표의 기준이므로, 테스트에서도 실제와 같은 길을 타게 하려면 진짜
/// 이미지가 있어야 한다.
final Uint8List _png2x1 = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x7B, 0x40, 0xE8, 0xDD, 0x00, 0x00, 0x00,
  0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0x0F, 0x06, 0x00,
  0x14, 0xF2, 0x05, 0xFB, 0xA4, 0x0D, 0x7C, 0x5E, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  late List<Offset> started;
  late List<Offset> updated;
  late int ended;
  late int cancelled;

  Widget build({Size size = const Size(400, 400)}) {
    started = <Offset>[];
    updated = <Offset>[];
    ended = 0;
    cancelled = 0;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: ScoreCanvas(
              displayBytes: _png2x1,
              isPdf: false,
              currentPdfPage: 0,
              pdfPageCount: 1,
              strokes: const <Stroke>[],
              currentStroke: null,
              onStrokeStart: started.add,
              onStrokeUpdate: updated.add,
              onStrokeEnd: () => ended++,
              onStrokeCancel: () => cancelled++,
              onPdfPageChanged: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  /// 악보 비율을 재는 것은 진짜 비동기다.
  ///
  /// ScoreCanvas 는 이미지 헤더를 읽어 비율을 얻는데, 위젯 테스트의 가짜
  /// 시계로는 그 디코딩이 끝나지 않는다. runAsync 안에서 진짜로 기다려야
  /// 한다. 이걸 빼먹으면 비율을 못 잰 채로 그려져서, 여백까지 포함한 옛
  /// 방식과 같은 값이 나온다.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pumpAndSettle();
  }

  /// 손가락은 kTouchSlop(18) 을 넘게 움직여야 제스처로 인정된다. 그래서
  /// 획의 첫 점은 손을 댄 자리가 아니라 그만큼 움직인 자리에서 잡힌다.
  /// 짚고 싶은 지점이 첫 점이 되도록 그 거리만큼 앞에서 시작한다.
  const Offset slop = Offset(30, 0);

  /// 두 손가락을 조금씩 번갈아 벌린다.
  ///
  /// 한 번에 크게 움직이면 한쪽만 움직인 순간에 제스처가 시작되면서, 손가락
  /// 사이의 중심이 한쪽으로 치우친 채로 잡힌다. 실제 손가락은 함께
  /// 움직이므로 시험도 그에 가깝게 해야 한다.
  Future<void> pinchOut(WidgetTester tester, Offset center) async {
    final TestGesture a = await tester.startGesture(center - const Offset(50, 0));
    final TestGesture b = await tester.startGesture(center + const Offset(50, 0));
    await tester.pump();
    for (int i = 0; i < 8; i++) {
      await a.moveBy(const Offset(-8, 0));
      await b.moveBy(const Offset(8, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> strokeAt(WidgetTester tester, Offset target) async {
    final TestGesture g = await tester.startGesture(target - slop);
    await tester.pump();
    await g.moveBy(slop);
    await tester.pump();
    await g.up();
    // 두 번 두드림을 기다리는 타이머가 남는다. 그대로 두면 위젯이 사라진
    // 뒤에 타이머가 살아 있다며 테스트가 실패한다.
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('필기 좌표는 화면이 아니라 악보 사각형을 기준으로 한다',
      (WidgetTester tester) async {
    // 400x400 자리에 2:1 악보 → 악보는 400x200, 위아래에 100씩 여백.
    await tester.pumpWidget(build());
    await settle(tester);

    // 화면 한가운데 = 악보의 한가운데.
    await strokeAt(tester, tester.getCenter(find.byType(ScoreCanvas)));

    expect(started, isNotEmpty);
    // 여백까지 셌다면 y 가 0.5 가 아닌 값이 나온다.
    expect(started.first.dx, closeTo(0.5, 0.01));
    expect(started.first.dy, closeTo(0.5, 0.01));
    expect(ended, 1);
  });

  testWidgets('악보 사각형의 위쪽 끝은 여백이 아니라 악보의 0 이다',
      (WidgetTester tester) async {
    await tester.pumpWidget(build());
    await settle(tester);

    // 악보는 세로 200 짜리로 가운데 놓인다. 그 위쪽 끝에서 조금 아래.
    final Rect box = tester.getRect(find.byType(ScoreCanvas));
    await strokeAt(tester, Offset(box.center.dx, box.top + 100 + 10));

    // 악보 높이 200 중 10 → 0.05. 화면 400 기준이면 0.275 가 나왔을 것이다.
    expect(started.first.dy, closeTo(0.05, 0.02));
  });

  testWidgets('두 손가락은 그리지 않고 확대한다', (WidgetTester tester) async {
    await tester.pumpWidget(build());
    await settle(tester);

    await pinchOut(tester, tester.getCenter(find.byType(ScoreCanvas)));

    expect(started, isEmpty, reason: '두 손가락으로는 획이 시작되면 안 된다');
    expect(ended, 0);

    // 확대되면 배율 표시가 나타난다.
    expect(find.byIcon(Icons.zoom_out_map_rounded), findsOneWidget);
  });

  testWidgets('그리다 손가락이 하나 더 얹히면 그리던 획을 버린다',
      (WidgetTester tester) async {
    await tester.pumpWidget(build());
    await settle(tester);

    final Offset center = tester.getCenter(find.byType(ScoreCanvas));
    final TestGesture a = await tester.startGesture(center);
    await tester.pump();
    await a.moveBy(const Offset(25, 0));
    await tester.pump();
    expect(started, hasLength(1));

    // 두 번째 손가락이 얹힌다.
    final TestGesture b = await tester.startGesture(center + const Offset(60, 0));
    await tester.pump();
    await a.moveBy(const Offset(-30, 0));
    await b.moveBy(const Offset(30, 0));
    await tester.pump();

    expect(cancelled, 1, reason: '확대하려던 것이므로 획을 버려야 한다');
    expect(ended, 0, reason: '버린 획을 저장하면 안 된다');

    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('확대해도 붙잡은 지점의 좌표는 그대로다',
      (WidgetTester tester) async {
    await tester.pumpWidget(build());
    await settle(tester);

    final Rect box = tester.getRect(find.byType(ScoreCanvas));
    final Offset c = box.center;

    // 확대하기 전, 화면 한가운데는 악보의 한가운데다.
    await strokeAt(tester, c);
    expect(started.first.dx, closeTo(0.5, 0.01));
    expect(started.first.dy, closeTo(0.5, 0.01));

    // 화면 한가운데를 붙잡고 두 손가락을 벌린다.
    //
    // 늘린 배율이 정확히 얼마인지는 중요하지 않다. 붙잡은 지점이 그대로
    // 있어야 한다는 것이 요점이다. 그래야 확대해도 필기가 제자리에 간다.
    await pinchOut(tester, c);

    // 확대됐는지 먼저 확인한다. 안 늘어났다면 이 시험은 아무것도 못 본다.
    expect(find.byIcon(Icons.zoom_out_map_rounded), findsOneWidget);

    started.clear();
    await strokeAt(tester, c);

    expect(started, isNotEmpty);
    expect(started.first.dx, closeTo(0.5, 0.02),
        reason: '붙잡은 지점은 늘려도 그 자리에 있어야 한다');
    expect(started.first.dy, closeTo(0.5, 0.02));
  });
}
