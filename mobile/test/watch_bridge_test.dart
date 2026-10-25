import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/timer_session.dart';
import 'package:ipsc_training/watch_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WatchBridge.channel, (_) async => null);
  });
  test(
    'forgotten watch loses approval and stale commands cannot execute',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WatchBridge.channel, (call) async {
            calls.add(call.method);
            return null;
          });
      final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
      addTearDown(bridge.dispose);
      bridge.enabled = bridge.approved = true;
      bridge.peer = 'old';
      bridge.peerCode = 123456;
      await bridge.forget();
      expect(calls, contains('forget'));
      expect(bridge.approved, false);
      expect(bridge.peer, null);
      expect(bridge.peerCode, null);
      final commands = <bool>[];
      bridge.attachPhone((start, delayMs) async {
        commands.add(start);
      });
      await bridge.handleCommand({'run': bridge.run, 'op': 1});
      expect(commands, isEmpty);
    },
  );

  test('automatic restore stays off when user disabled connection', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WatchBridge.channel, (call) async {
          calls.add(call.method);
          return false;
        });
    final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
    await bridge.restore();
    expect(calls, ['preferences']);
    expect(bridge.enabled, false);
    bridge.dispose();
  });

  test(
    'disposing the screen closes transport without saving user opt-out',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WatchBridge.channel, (call) async {
            calls.add(call.method);
            return null;
          });
      final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
      bridge.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('close'));
      expect(calls, isNot(contains('stop')));
    },
  );

  test(
    'watch delay reaches phone once and invalid delays never start',
    () async {
      final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
      addTearDown(bridge.dispose);
      bridge.selectPhone(true);
      bridge.enabled = bridge.approved = true;
      bridge.phoneState(WatchPhase.idle, [], canControl: true);
      final delays = <int?>[];
      bridge.attachPhone((start, delayMs) async {
        if (start) delays.add(delayMs);
      });
      for (final invalid in [-1, 60001, 0.5, '3000']) {
        await bridge.handleCommand({
          'run': bridge.run,
          'op': 1,
          'delayMs': invalid,
        });
      }
      expect(delays, isEmpty);
      await bridge.handleCommand({'run': bridge.run, 'op': 1, 'delayMs': 0});
      await bridge.handleCommand({'run': bridge.run, 'op': 1, 'delayMs': 5000});
      expect(delays, [0, 5000]);
    },
  );

  test('wire vector matches watch; first shot has no fabricated split', () {
    final bytes = watchPacket(
      run: 7,
      revision: 9,
      phase: WatchPhase.running,
      times: [1.25, 1.64],
      phone: true,
      controllable: true,
    );
    expect(
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '0132020007000000090000006806000086010000',
    );
    final first = ByteData.sublistView(
      watchPacket(
        run: 7,
        revision: 1,
        phase: WatchPhase.running,
        times: [1.25],
      ),
    );
    expect(first.getUint32(16, Endian.little), 0xffffffff);
  });

  test(
    'unapproved, stale and external commands never invoke phone control',
    () async {
      final session = TimerSession(onImport: (_, _) async => true);
      final bridge = WatchBridge(session);
      addTearDown(bridge.dispose);
      final calls = <bool>[];
      bridge.attachPhone((value, delayMs) async {
        calls.add(value);
      });
      bridge.selectPhone(true);
      bridge.phoneState(WatchPhase.idle, [], canControl: true);
      bridge.enabled = true;
      await bridge.handleCommand({'run': bridge.run, 'op': 1});
      expect(calls, isEmpty);
      bridge.approved = true;
      await bridge.handleCommand({'run': bridge.run - 1, 'op': 1});
      expect(calls, isEmpty);
      bridge.selectPhone(false);
      await bridge.handleCommand({'run': bridge.run, 'op': 1});
      expect(calls, isEmpty);
    },
  );

  test(
    'start/finish, busy and detached-screen gates preserve run identity',
    () async {
      final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
      addTearDown(bridge.dispose);
      bridge.selectPhone(true);
      bridge.phoneState(WatchPhase.idle, [], canControl: true);
      bridge.enabled = bridge.approved = true;
      final calls = <bool>[];
      bridge.attachPhone((start, delayMs) async {
        calls.add(start);
        bridge.phoneState(
          start ? WatchPhase.preparing : WatchPhase.finished,
          [],
          canControl: true,
          newRun: start,
        );
      });
      final oldRun = bridge.run;
      await bridge.handleCommand({'run': oldRun, 'op': 1});
      expect(bridge.run, isNot(oldRun));
      expect(calls, [true]);
      await bridge.handleCommand({'run': oldRun, 'op': 2});
      expect(calls, [true]);
      await bridge.handleCommand({'run': bridge.run, 'op': 2});
      expect(calls, [true, false]);
      final done = Completer<void>();
      bridge.attachPhone((_, _) => done.future);
      final pending = bridge.handleCommand({'run': bridge.run, 'op': 1});
      await bridge.handleCommand({'run': bridge.run, 'op': 1});
      done.complete();
      await pending;
      bridge.detachPhone();
      await bridge.handleCommand({'run': bridge.run, 'op': 1});
      expect(bridge.controllable, false);
      expect(bridge.phase, WatchPhase.unavailable);
    },
  );
  test(
    'repeated finish for an already finished phone run is harmless',
    () async {
      final packets = <Uint8List>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WatchBridge.channel, (call) async {
            if (call.method == 'publish') {
              packets.add(Uint8List.fromList(call.arguments as Uint8List));
            }
            return null;
          });
      final bridge = WatchBridge(TimerSession(onImport: (_, _) async => true));
      addTearDown(bridge.dispose);
      var commands = 0;
      bridge.selectPhone(true);
      bridge.attachPhone((_, _) async {
        commands++;
      });
      bridge.enabled = bridge.approved = true;
      bridge.phoneState(WatchPhase.finished, [], canControl: true);
      await bridge.handleCommand({'run': bridge.run, 'op': 2});
      await Future<void>.delayed(Duration.zero);
      expect(commands, 0);
      expect(packets.last[1] & 64, 0);
      final oldRun = bridge.run;
      bridge.phoneState(WatchPhase.running, [], canControl: true, newRun: true);
      await bridge.handleCommand({'run': oldRun, 'op': 2});
      await Future<void>.delayed(Duration.zero);
      expect(commands, 0);
      expect(bridge.phase, WatchPhase.running);
      expect(packets.last[1] & 64, 0);
    },
  );
}
