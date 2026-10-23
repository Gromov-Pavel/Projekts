import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/video_timeline.dart';

void main() {
  testWidgets('two tracks support tap seek, slider drag and horizontal zoom', (
    tester,
  ) async {
    final seeks = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ShotTimeline(
              duration: 10,
              position: 2,
              primaryTimes: const [1, 3],
              comparisonTimes: const [1.5, 3.5],
              candidates: const [4],
              onSeek: seeks.add,
            ),
          ),
        ),
      ),
    );
    expect(find.text('A · Выстрелы'), findsOneWidget);
    expect(find.text('B · Выстрелы'), findsOneWidget);
    expect(find.text('? · Кандидаты'), findsOneWidget);
    expect(find.text('Время от старта, с'), findsOneWidget);
    final track = find.byKey(const ValueKey('shot-timeline-track'));
    final origin = tester.getTopLeft(track);
    await tester.tapAt(origin + const Offset(96, 50));
    expect(seeks.single, closeTo(2.5, .01));
    await tester.drag(find.byType(Slider), const Offset(120, 0));
    expect(seeks.last, greaterThan(2.5));
    await tester.tap(find.text('×2'));
    await tester.pumpAndSettle();
    expect(tester.getSize(track).width, 720);
    final horizontal = find.byType(SingleChildScrollView);
    await tester.drag(horizontal, const Offset(-180, 0));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid or prestart positions remain safe on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShotTimeline(
            duration: 0,
            position: -2,
            primaryTimes: const [-1, double.nan, 2],
            onSeek: (_) {},
          ),
        ),
      ),
    );
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    expect(find.text('B · Выстрелы'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'unconfirmed B candidates have separate semantics and invalid times are skipped',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShotTimeline(
              duration: 10,
              position: 0,
              primaryTimes: const [],
              candidates: const [double.nan, -1, 11],
              comparisonCandidates: const [2, 3, double.infinity, -2, 12],
              onSeek: (_) {},
            ),
          ),
        ),
      );
      expect(find.text('? · Кандидаты'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          RegExp(r'Кандидаты A \(\?\): 0\. Кандидаты B \(\?\): 2\.'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
