import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/timer_protocol.dart';

void main() {
  final fixtures = jsonDecode(
    File('../fixtures/timer-protocol-vectors.json').readAsStringSync(),
  );
  for (final v in fixtures['vectors']) {
    test('shared protocol vector: ${v['id']}', () {
      final d = TimerProtocols.decoder(v['id']);
      final frames = (v['frames'] as List)
          .map((f) => List<int>.from(f))
          .toList();
      final events = frames.expand(d.add).toList();
      expect(events.map((e) => e.kind), [
        TimerEventKind.start,
        TimerEventKind.shot,
        TimerEventKind.stop,
      ]);
      expect(events[1].seconds, v['expectedTimeMs'] / 1000);
      expect(d.add(frames[1]), isEmpty);
      expect(TimerProtocols.controlPacket(v['id'], true), v['start']);
      expect(TimerProtocols.controlPacket(v['id'], false), v['stop']);
    });
  }
  test('ProTimer fragmented JSON, quoted braces and malformed fields', () {
    final bytes = ascii.encode(
      '{"t":"string-started","start":9,"note":"}\\\"{"}{"t":"shot","start":9,"index":0,"timeInMs":1641}',
    );
    for (var cut = 1; cut < bytes.length; cut++) {
      final d = TimerProtocols.decoder('protimer-v2');
      final events = [
        ...d.add(bytes.sublist(0, cut)),
        ...d.add(bytes.sublist(cut)),
      ];
      expect(events.length, 2);
      expect(events[1].milliseconds, 1641);
    }
    final d = TimerProtocols.decoder('protimer-v2');
    expect(
      d.add(ascii.encode('{"t":"shot","start":null,"index":0,"timeInMs":4}')),
      isEmpty,
    );
    expect(d.add(ascii.encode('{"t":"string-started","start":"9"}')), isEmpty);
  });
  test('RangeTech history cannot appear as live shots', () {
    final d = TimerProtocols.decoder('rangetech');
    d.add(ascii.encode('!MSG:BEEP|9'));
    expect(d.add(ascii.encode('!LSHOT1640|0|9')), isEmpty);
    expect(d.add(ascii.encode('!SHOT1640|0|8')), isEmpty);
  });
}
