import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/video_playback_clock.dart';

void main() {
  void sample(
    PlaybackClock clock,
    double position,
    double now, {
    bool playing = true,
    bool buffering = false,
    double speed = 1,
  }) => clock.observe(
    position: position,
    playing: playing,
    buffering: buffering,
    speed: speed,
    now: now,
  );

  test('independent polling phases project onto the same playback time', () {
    final a = PlaybackClock(), b = PlaybackClock();
    sample(a, 1, 1);
    sample(b, .8, .8);
    expect(a.projectedPosition(1), closeTo(b.projectedPosition(1), 1e-9));
    sample(a, 1, 1.1);
    sample(b, .8, 1.1);
    expect(a.projectedPosition(1.2), closeTo(1.2, 1e-9));
    expect(b.projectedPosition(1.2), closeTo(1.2, 1e-9));
  });

  test('fresh sample and seeks replace the old extrapolation anchor', () {
    final clock = PlaybackClock();
    sample(clock, 1, 1);
    sample(clock, 1.25, 1.3);
    expect(clock.projectedPosition(1.4), closeTo(1.35, 1e-9));
    sample(clock, 8, 1.5);
    expect(clock.projectedPosition(1.6), closeTo(8.1, 1e-9));
    clock.reset();
    expect(clock.projectedPosition(2), 0);
    sample(clock, 8, 2);
    expect(clock.projectedPosition(2.1), closeTo(8.1, 1e-9));
  });

  test('pause and buffering freeze; resume and speed changes reanchor', () {
    final clock = PlaybackClock();
    sample(clock, 2, 1, speed: .5);
    expect(clock.projectedPosition(2), 2.5);
    sample(clock, 2, 2, playing: false, speed: .5);
    expect(clock.projectedPosition(3), 2);
    sample(clock, 2, 3, buffering: true, speed: .5);
    expect(clock.projectedPosition(4), 2);
    sample(clock, 2, 4, speed: .5);
    expect(clock.projectedPosition(5), 2.5);
    sample(clock, 2, 5, speed: 2);
    expect(clock.projectedPosition(5.5), 3);
    expect(clock.projectedPosition(4), 2);
  });

  test('invalid timestamps and samples fail at the boundary', () {
    final clock = PlaybackClock();
    expect(() => sample(clock, 0, double.nan), throwsArgumentError);
    expect(() => sample(clock, double.infinity, 0), throwsArgumentError);
    expect(() => sample(clock, 0, 0, speed: 0), throwsArgumentError);
    expect(() => clock.projectedPosition(double.infinity), throwsArgumentError);
  });
}
