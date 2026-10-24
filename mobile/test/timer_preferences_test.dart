import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/timer_preferences.dart';

void main() {
  test('saved timers persist opt-out, confirmed protocol and selected source atomically', () async {
    final dir = await Directory.systemTemp.createTemp('ipsc-timers-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/timers.json');
    final prefs = TimerPreferences();
    prefs.timers['a'] = SavedTimer(
      'a',
      'Timer A',
      autoConnect: false,
      profile: 'legacy',
    );
    prefs.timers['b'] = SavedTimer('b', 'Timer B');
    prefs.selectedId = 'b';
    await prefs.save(file);
    final restored = TimerPreferences()..read(await file.readAsString());
    expect(restored.ordered.map((t) => t.id), ['b', 'a']);
    expect(restored.timers['a']!.autoConnect, false);
    expect(restored.timers['a']!.profile, 'legacy');
    expect(await File('${file.path}.tmp').exists(), false);
  });
  test('invalid entries do not become auto-connect targets', () {
    final prefs = TimerPreferences()
      ..read(
        '{"schema":1,"selectedId":"missing","timers":[{"id":"","name":"bad"},{"id":4,"name":"bad"},{"id":"ok","name":"Timer","autoConnect":"yes"}]}',
      );
    expect(prefs.selectedId, null);
    expect(prefs.timers.keys, ['ok']);
    expect(prefs.timers['ok']!.autoConnect, false);
    expect(() => prefs.read('{"schema":2,"timers":[]}'), throwsFormatException);
    expect(prefs.timers.keys, ['ok']);
  });
}
