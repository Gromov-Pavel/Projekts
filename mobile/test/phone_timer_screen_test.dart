import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/phone_timer_screen.dart';
import 'package:ipsc_training/watch_bridge.dart';
import 'package:ipsc_training/timer_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final calls = <String>[];
  const audio = MethodChannel('pace/audio');
  const events = MethodChannel('pace/microphone');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    directory = Directory.systemTemp.createTempSync('phone-timer-test-');
    File('${directory.path}/phone-timer-settings.json')
        .writeAsStringSync('{"delay":0,"par":0}');
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(
      permissions,
      (_) async => <int, int>{7: 1},
    );
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(audio, (call) async {
      calls.add(call.method);
      if (call.method == 'beep') {
        expectSync(call.arguments['durationMs'], 600);
        expectSync(call.arguments['gain'], 1);
        return {
          'at': 100.0,
          'durationMs': 600,
          'mediaVolume': 3,
          'mediaMax': 15,
        };
      }
      if (call.method == 'audioStatus') {
        return {'mediaVolume': 3, 'mediaMax': 15};
      }
      return {'at': 99.0, 'sampleRate': 48000};
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [audio, events, permissions, paths]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    directory.deleteSync(recursive: true);
  });

  Future<void> ready(WidgetTester tester) async {
    final deadline = Stopwatch()..start();
    for (var i = 0; deadline.elapsed < const Duration(seconds: 15); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      final start = find.widgetWithText(FilledButton, 'Начать');
      final loaded =
          start.evaluate().isEmpty ||
          tester.widget<FilledButton>(start).onPressed != null;
      if (i >= 5 && loaded) return;
    }
    fail('Phone timer did not finish loading its settings within 15 seconds');
  }

  Future<void> frame(WidgetTester tester, double at, double peak) async {
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'pace/microphone',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'at': at,
        'peak': peak,
        'rms': peak / 3,
        'toneRatio': 0.0,
        'clipped': false,
      }),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('live shots show first, splits and save only once explicitly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <List<double>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneTimerScreen(
          onSave: (times, source) async {
            expect(source, 'Микрофон телефона');
            saved.add(times);
            return true;
          },
        ),
      ),
    );
    await ready(tester);
    expect(calls, isNot(contains('micStart')));
    await tester.tap(find.text('Начать'));
    await tester.pump(const Duration(milliseconds: 1));
    await ready(tester);
    expect(calls.indexOf('micStart'), lessThan(calls.indexOf('beep')));
    await frame(tester, 100.5, .8);
    await frame(tester, 100.6, .001);
    await frame(tester, 100.63, .001);
    await frame(tester, 101, .8);
    expect(find.text('Выстрелов: 2'), findsOneWidget);
    expect(find.text('Первый: 0.50 с'), findsOneWidget);
    expect(find.text('Последний сплит: 0.50 с'), findsOneWidget);
    await tester.tap(find.text('Остановить'));
    await ready(tester);
    await tester.ensureVisible(find.text('Выстрел 2: 1.00 с'));
    expect(find.text('Выстрел 1: 0.50 с'), findsOneWidget);
    expect(find.text('Выстрел 2: 1.00 с'), findsOneWidget);
    expect(saved, isEmpty);
    await tester.ensureVisible(find.text('Начать'));
    await tester.tap(find.text('Начать'));
    await tester.pumpAndSettle();
    expect(find.text('Серия не сохранена'), findsOneWidget);
    await tester.tap(find.text('Оставить'));
    await tester.pumpAndSettle();
    expect(find.text('Выстрелов: 2'), findsOneWidget);
    await tester.ensureVisible(find.text('Сохранить серию'));
    await tester.tap(find.text('Сохранить серию'));
    await tester.pump();
    expect(saved, [
      [.5, 1.0],
    ]);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Сохранено'),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls, containsAll(['micStop', 'stopBeep']));
  });

  testWidgets(
    'microphone preview stores no shots and background stops capture',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: PhoneTimerScreen(onSave: (_, _) async => true)),
      );
      await ready(tester);
      await tester.scrollUntilVisible(
        find.text('Настройки таймера'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Настройки таймера'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Проверить микрофон'));
      await tester.tap(find.text('Проверить микрофон'));
      await ready(tester);
      await frame(tester, 101, .9);
      expect(calls, isNot(contains('beep')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await ready(tester);
      expect(calls, contains('micStop'));
      expect(calls, contains('stopBeep'));
      await tester.ensureVisible(find.text('Выстрелов: 0'));
      expect(find.text('Выстрелов: 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
  testWidgets(
    'narrow phone layout has no overflow and signal preview needs no microphone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: PhoneTimerScreen(onSave: (_, _) async => true)),
      );
      await ready(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Настройки таймера'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Настройки таймера'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Фильтр эха'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Фильтр эха'));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );
      final echoSlider = find.byWidgetPredicate(
        (widget) => widget is Slider && widget.min == 80 && widget.max == 400,
      );
      await tester.ensureVisible(echoSlider);
      expect(tester.widget<Slider>(echoSlider).onChanged, isNull);
      await tester.scrollUntilVisible(
        find.text('Проверить сигнал'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Проверить сигнал'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Проверить сигнал'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      expect(calls, contains('beep'));
      expect(calls, isNot(contains('micStart')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'active timer survives background and watch can finish; background starts are rejected',
    (tester) async {
      final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WatchBridge.channel, (_) async => null);
      bridge.selectPhone(true);
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneTimerScreen(
            onSave: (_, _) async => true,
            watchBridge: bridge,
          ),
        ),
      );
      await ready(tester);
      bridge.enabled = bridge.approved = true;
      await tester.runAsync(() async {
        await bridge.handleCommand({
          'run': bridge.run,
          'op': 1,
          'delayMs': 150,
        });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(calls, isNot(contains('beep')));
        await Future<void>.delayed(const Duration(milliseconds: 180));
      });
      await tester.pump(const Duration(milliseconds: 1));
      await ready(tester);
      await tester.pump();
      expect(calls, contains('micStart'));
      expect(calls, contains('beep'));
      expect(bridge.phase, WatchPhase.running);
      final stoppedBefore = calls.where((c) => c == 'micStop').length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bridge.foreground(false);
      await tester.pump(const Duration(seconds: 2));
      expect(calls.where((c) => c == 'micStop').length, stoppedBefore);
      expect(bridge.phase, WatchPhase.running);
      await tester.runAsync(
        () => bridge.handleCommand({'run': bridge.run, 'op': 2}),
      );
      await tester.pump();
      expect(bridge.phase, WatchPhase.finished);
      expect(calls, contains('micStop'));
      final starts = calls.where((c) => c == 'micStart').length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.runAsync(
        () => bridge.handleCommand({'run': bridge.run, 'op': 1}),
      );
      await tester.pump();
      expect(calls.where((c) => c == 'micStart').length, starts);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      bridge.dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
