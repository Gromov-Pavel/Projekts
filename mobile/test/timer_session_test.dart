import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:ipsc_training/timer_protocol.dart';
import 'package:ipsc_training/timer_session.dart';
import 'package:ipsc_training/timers_screen.dart';

class _ServiceSession extends TimerSession {
  _ServiceSession() : super(onImport: (_, _) async => true);
  int count = 0;
  @override
  int get connectedCount => count;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native service starts once and stops after last connection', () async {
    const channel = MethodChannel('pace/audio');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return call.method == 'androidSdk' ? 32 : null;
        });
    final session = _ServiceSession()..count = 1;
    await session.refreshBackgroundService();
    expect(session.serviceRunning, isTrue);
    session.count = 2;
    await session.refreshBackgroundService();
    session.count = 0;
    await session.refreshBackgroundService();
    expect(session.serviceRunning, isFalse);
    expect(calls, ['androidSdk', 'timerServiceStart', 'timerServiceStop']);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  const start = [0xf8, 0xf9, 0x34, 3, 0xf9, 0xf8];
  const shot = [0xf8, 0xf9, 0x36, 0, 4, 36, 2, 12, 0xf9, 0xf8];
  const stop = [0xf8, 0xf9, 0x18, 3, 0xf9, 0xf8];
  TimerLink link(String id) {
    final value = TimerLink(BluetoothDevice.fromId(id));
    value.profile = TimerProtocols.legacyId;
    value.decoder = TimerProtocols.decoder(value.profile);
    return value;
  }

  testWidgets(
    'fullscreen live fits portrait and landscape and keeps the series',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final size in [const Size(360, 640), const Size(640, 320)]) {
        tester.view.physicalSize = size;
        final session = TimerSession(onImport: (_, _) async => true);
        final device = link('00:11:22:33:44:55');
        session.links[device.device.remoteId.str] = device;
        session.selectedId = device.device.remoteId.str;
        session.receive(device, [...start, ...shot]);
        await tester.pumpWidget(
          MaterialApp(home: TimersScreen(session: session)),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byTooltip('На весь экран'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('На весь экран'));
        await tester.pumpAndSettle();
        expect(find.text('4.36 с'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Вернуться к тренировке'));
        await tester.pumpAndSettle();
        expect(device.active!.times, [4.36]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  test(
    'new start archives and autosaves previous run without a stop packet',
    () async {
      final saved = <List<double>>[];
      final session = TimerSession(
        onImport: (times, source) async {
          saved.add(times);
          return true;
        },
      );
      final device = link('00:11:22:33:44:55');
      session.receive(device, [...start, ...shot]);
      final old = device.active!;
      session.receive(device, [0xf8, 0xf9, 0x34, 4, 0xf9, 0xf8]);
      await Future<void>.delayed(Duration.zero);
      expect(saved, [
        [4.36],
      ]);
      expect(old.saved, isTrue);
      expect(device.active!.id, isNot(old.id));
      expect(device.active!.times, isEmpty);
    },
  );

  test('manual finish saves immediately, keeps per-device series isolated and dedups', () async {
    final sources = <String>[];
    final session = TimerSession(
      onImport: (times, source) async {
        sources.add(source);
        return true;
      },
    );
    final a = link('00:11:22:33:44:55');
    final b = link('00:11:22:33:44:66');
    session.receive(a, [...start, ...shot]);
    session.receive(b, start);
    final pending = a.active!;
    session.finishSeries(a);
    await Future<void>.delayed(Duration.zero);
    await session.saveSeries(pending);
    expect(sources.length, 1);
    expect(sources.single, contains(pending.id));
    expect(b.active!.times, isEmpty);
    expect(a.active, isNull);
  });

  test(
    'failed autosave retains pending for retry using the same source id',
    () async {
      final sources = <String>[];
      final session = TimerSession(
        onImport: (times, source) async {
          sources.add(source);
          return sources.length > 1;
        },
      );
      final device = link('00:11:22:33:44:55');
      session.receive(device, [...start, ...shot, ...stop]);
      await Future<void>.delayed(Duration.zero);
      final pending = device.pending.single;
      expect(pending.saved, isFalse);
      expect(pending.times, [4.36]);
      await session.saveSeries(pending);
      expect(pending.saved, isTrue);
      expect(sources[0], sources[1]);
    },
  );

  test('automatic protocol recognition waits for valid start, preserves fragmented frame and records confirmed profile', () {
    final session = TimerSession(onImport: (_, _) async => true);
    final device = TimerLink(BluetoothDevice.fromId('00:11:22:33:44:77'));
    device.profile = TimerProtocols.autoId;
    device.decoder = TimerProtocols.decoder(TimerProtocols.autoId);
    session.receive(device, [1, 2, 3, ...shot]);
    expect(device.profile, TimerProtocols.autoId);
    expect(device.active, isNull);
    session.receive(device, start.sublist(0, 3));
    expect(device.profile, TimerProtocols.autoId);
    session.receive(device, [...start.sublist(3), ...shot]);
    expect(device.profile, TimerProtocols.legacyId);
    expect(device.active!.times, [4.36]);
    session.receive(device, shot);
    expect(device.active!.times, [4.36]);
  });

  test('full raw journal does not interrupt live timing', () {
    final session = TimerSession(onImport: (_, _) async => true)..full = true;
    final device = link('00:11:22:33:44:55');
    session.receive(device, [...start, ...shot]);
    expect(device.active!.times, [4.36]);
  });
}
