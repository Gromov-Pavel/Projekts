import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/live_shot_detector.dart';

MicFrame frame(
  double at, {
  double peak = .8,
  double rms = .25,
  double tone = 0,
}) => MicFrame(at: at, rms: rms, peak: peak, toneRatio: tone);
void quiet(LiveShotDetector d, double at) {
  d.add(frame(at, peak: 0, rms: 0));
  d.add(frame(at + .01, peak: 0, rms: 0));
  d.add(frame(at + .02, peak: 0, rms: 0));
}

void main() {
  test('time from start and successive splits use microphone timestamps', () {
    final d = LiveShotDetector()..start(100);
    expect(d.add(frame(99)), isNull);
    expect(d.add(frame(100.5)), closeTo(.5, 1e-8));
    quiet(d, 100.52);
    expect(d.add(frame(100.78)), closeTo(.78, 1e-8));
  });
  test('own sustained beep, onset and silent frames do not count', () {
    final d = LiveShotDetector()..start(10);
    expect(d.add(frame(10.02)), isNull);
    for (var i = 1; i <= 60; i++) {
      expect(d.add(frame(10 + i * .01, tone: .95)), isNull);
    }
    expect(d.add(frame(10.7)), closeTo(.7, 1e-8));
  });
  test('echo refractory and hysteresis reject repeated sustained impulses', () {
    final d = LiveShotDetector()..start(0);
    expect(d.add(frame(.5)), .5);
    expect(d.add(frame(.7)), isNull);
    quiet(d, .72);
    expect(d.add(frame(.76)), .76);
    quiet(d, .77);
    expect(d.add(frame(.82)), isNull);
    expect(d.add(frame(.9)), isNull);
    quiet(d, .91);
    expect(d.add(frame(1.0)), 1.0);
  });
  test(
    'higher sensitivity accepts smaller impulse while low sensitivity rejects',
    () {
      final low = LiveShotDetector(sensitivity: 0)..start(0),
          high = LiveShotDetector(sensitivity: 100)..start(0);
      expect(low.add(frame(.5, peak: .02, rms: .005)), isNull);
      expect(high.add(frame(.5, peak: .02, rms: .005)), .5);
    },
  );
  test('stopped, duplicate and invalid frames never add shots', () {
    final d = LiveShotDetector()..start(0);
    expect(d.add(frame(.5)), .5);
    expect(d.add(frame(.5)), isNull);
    expect(d.add(frame(double.nan)), isNull);
    d.stop();
    expect(d.add(frame(1)), isNull);
    expect(
      () => MicFrame.fromMap({'at': 1, 'rms': -1, 'peak': 1, 'toneRatio': 0}),
      throwsFormatException,
    );
    expect(
      () => d.configure(sensitivity: 101, minInterval: .1),
      throwsArgumentError,
    );
  });
  test('broadband impulse during a long tone remains eligible', () {
    final d = LiveShotDetector()..start(100);
    expect(d.add(frame(100.2, tone: .95)), isNull);
    expect(d.add(frame(100.3, tone: .4)), closeTo(.3, 1e-8));
  });
  test('minimum interval can retain an 80ms split after quiet rearm', () {
    final d = LiveShotDetector(minInterval: .06)..start(0);
    expect(d.add(frame(.5)), .5);
    quiet(d, .51);
    expect(d.add(frame(.58)), .58);
  });
  test('echo filter rejects weaker delayed copy but retains equally strong fast shot', () {
    final d = LiveShotDetector(minInterval: .06, echoWindow: .20)..start(0);
    expect(d.add(frame(.5)), .5);
    quiet(d, .51);
    expect(d.add(frame(.62, peak: .3, rms: .08)), isNull);
    quiet(d, .63);
    expect(d.add(frame(.68)), .68);
  });
  test(
    'echo filter can be disabled or expire without extending suppression',
    () {
      for (final enabled in [true, false]) {
        final d = LiveShotDetector(
          minInterval: .06,
          echoSuppression: enabled,
          echoWindow: .18,
        )..start(0);
        expect(d.add(frame(.5)), .5);
        quiet(d, .51);
        expect(d.add(frame(.62, peak: .3, rms: .08)), enabled ? isNull : .62);
        quiet(d, .63);
        expect(d.add(frame(.9, peak: .3, rms: .08)), .9);
      }
    },
  );
}
