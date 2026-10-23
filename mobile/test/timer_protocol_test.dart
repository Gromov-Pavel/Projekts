import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/timer_protocol.dart';

void main() {
  const start = [0xf8, 0xf9, 0x34, 3, 0xf9, 0xf8];
  const stop = [0xf8, 0xf9, 0x18, 3, 0xf9, 0xf8];
  // Literal example from the implementer's protocol document, not a user capture.
  const shot = [0xf8, 0xf9, 0x36, 0, 4, 0x24, 2, 0x0c, 0xf9, 0xf8];

  test('zero and repeated times cannot create an invalid run', () {
    final d = TimerProtocols.decoder(TimerProtocols.legacyId);
    d.add(start);
    expect(d.add([0xf8, 0xf9, 0x36, 0, 0, 0, 1, 0x0c, 0xf9, 0xf8]), isEmpty);
    expect(d.add(shot).single.seconds, 4.36);
    expect(d.add([0xf8, 0xf9, 0x36, 0, 4, 0x24, 3, 0x0c, 0xf9, 0xf8]), isEmpty);
  });

  test('raw and unknown profiles never invent times', () {
    for (final id in [TimerProtocols.rawId, 'unknown-firmware']) {
      expect(TimerProtocols.decoder(id).add([...start, ...shot]), isEmpty);
    }
  });

  test('explicit legacy decodes documented time preserving wire index', () {
    final decoder = TimerProtocols.decoder(TimerProtocols.legacyId);
    final events = decoder.add([...start, ...shot, ...stop]);
    expect(events.map((e) => e.kind), [
      TimerEventKind.start,
      TimerEventKind.shot,
      TimerEventKind.stop,
    ]);
    expect(events[1].centiseconds, 436);
    expect(events[1].seconds, 4.36);
    expect(events[1].shotIndex, 2);
    expect(events[1].sessionId, 3);
    expect(events[1].profileId, TimerProtocols.legacyId);
  });

  test('every split boundary reassembles and does not merge devices', () {
    final packet = [...start, ...shot];
    for (var split = 1; split < packet.length; split++) {
      final a = TimerProtocols.decoder(TimerProtocols.legacyId);
      final b = TimerProtocols.decoder(TimerProtocols.legacyId);
      final events = [
        ...a.add(packet.sublist(0, split)),
        ...a.add(packet.sublist(split)),
      ];
      expect(
        events.where((e) => e.kind == TimerEventKind.shot).single.seconds,
        4.36,
      );
      expect(b.add(shot), isEmpty);
    }
  });

  test(
    'malformed boundaries, invalid centiseconds and oversized input rejected',
    () {
      final d = TimerProtocols.decoder(TimerProtocols.legacyId);
      d.add(start);
      expect(d.add([0, 1, 2, ...shot.sublist(0, 8), 0, 0]), isEmpty);
      expect(d.add([0xf8, 0xf9, 0x36, 0, 4, 100, 2, 0, 0xf9, 0xf8]), isEmpty);
      expect(d.add(List.filled(4097, 0)), isEmpty);
      expect(d.add(shot).single.seconds, 4.36);
    },
  );

  test(
    'duplicate start/shot/stop and mismatched stop do not reset active series',
    () {
      final d = TimerProtocols.decoder(TimerProtocols.legacyId);
      d.add([...start, ...shot]);
      expect(d.add([...start, ...shot]), isEmpty);
      expect(d.add([0xf8, 0xf9, 0x18, 4, 0xf9, 0xf8]), isEmpty);
      expect(d.add(stop).single.kind, TimerEventKind.stop);
      expect(d.add([...stop, ...shot]), isEmpty);
      expect(d.add([...start, ...shot]).length, 2);
    },
  );
}
