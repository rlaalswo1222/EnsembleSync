import 'package:ensemble_sync/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void configurePhoneView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
  }

  testWidgets('home screen uses a full white mobile surface', (tester) async {
    configurePhoneView(tester);

    await tester.pumpWidget(const EnsembleSyncApp());

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.white);
    expect(find.text('Bandly'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home form does not overflow when the keyboard opens',
      (tester) async {
    configurePhoneView(tester);
    await tester.pumpWidget(const EnsembleSyncApp());

    await tester.tap(find.byType(TextField).first);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
