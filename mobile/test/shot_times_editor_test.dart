import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/shot_times_editor.dart';

void main() {
  testWidgets('shot columns wrap, edit individual times and recompute splits', (
    tester,
  ) async {
    final controller = TextEditingController(text: '1.00 2.00 3.00');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 300,
              child: ShotTimesEditor(controller: controller),
            ),
          ),
        ),
      ),
    );
    final first = find.byKey(const ValueKey('shot-time-0'));
    final second = find.byKey(const ValueKey('shot-time-1'));
    final third = find.byKey(const ValueKey('shot-time-2'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(
      tester.getTopLeft(third).dy,
      greaterThan(tester.getTopLeft(second).dy),
    );
    await tester.enterText(second, '2.20');
    await tester.pump();
    expect(controller.text, '1.00 2.20 3.00');
    expect(find.text('Сплит: 1.20'), findsOneWidget);
    expect(find.text('Сплит: 0.80'), findsOneWidget);
    await tester.tap(find.byTooltip('Удалить выстрел 2'));
    await tester.pump();
    expect(controller.text, '1.00 3.00');
    expect(find.text('Сплит: 2.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
