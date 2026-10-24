import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/timer_session.dart';
import 'package:ipsc_training/watch_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WatchBridge.channel, (_) async => null);
  });
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
      bridge.attachPhone((value) async {
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
      bridge.attachPhone((start) async {
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
      bridge.attachPhone((_) => done.future);
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
}
