import 'dart:math' as math;

/// Compact 20 ms audio features; times remain in the original video timeline.
class AudioFrame {
  const AudioFrame(this.time, this.rms, this.tone, [this.frequencyHz]);
  final double time;
  final double rms;
  final double tone;
  final double? frequencyHz;
}

/// A tonal proposal, not a labelled start or calibrated probability.
class BeepCandidate {
  const BeepCandidate({
    required this.time,
    required this.duration,
    required this.confidence,
    this.frequencyHz,
    this.atBoundary = false,
  });
  final double time;
  final double duration;
  final double confidence;
  final double? frequencyHz;
  final bool atBoundary;
}

class AudioAnalysis {
  const AudioAnalysis({
    this.beep,
    required this.shotCandidates,
    this.beepCandidates = const [],
  });
  final double? beep;
  final List<BeepCandidate> beepCandidates;
  List<BeepCandidate> get candidates => beepCandidates;
  final List<double> shotCandidates;
}

/// Scans several tone frequencies instead of assuming a particular timer model.
List<AudioFrame> pcmFeatures(List<double> samples, int sampleRate) {
  if (sampleRate < 8000) throw ArgumentError('Sample rate must be >= 8000');
  final size = (sampleRate * .02).round();
  final frames = <AudioFrame>[];
  for (var offset = 0; offset + size <= samples.length; offset += size) {
    var energy = 0.0;
    for (var i = 0; i < size; i++) {
      energy += samples[offset + i] * samples[offset + i];
    }
    var peak = 0.0;
    var frequency = 0.0;
    for (var hz = 1250; hz <= math.min(5000, sampleRate / 2 - 250); hz += 50) {
      final coefficient = 2 * math.cos(2 * math.pi * hz / sampleRate);
      var previous = 0.0;
      var before = 0.0;
      for (var i = 0; i < size; i++) {
        final value = samples[offset + i] + coefficient * previous - before;
        before = previous;
        previous = value;
      }
      final power =
          previous * previous +
          before * before -
          coefficient * previous * before;
      if (power > peak) {
        peak = power;
        frequency = hz.toDouble();
      }
    }
    frames.add(
      AudioFrame(
        offset / sampleRate,
        math.sqrt(energy / size),
        energy > 0 ? (2 * peak / (size * energy)).clamp(0, 1).toDouble() : 0,
        frequency,
      ),
    );
  }
  return frames;
}

/// A weak tone needs a stable frequency and sustained support, rather than an
/// absolute recording level. Short masking gaps are tolerated within a pulse.
bool _sameToneFamily(double first, double current) {
  if (!current.isFinite || current < 1250 || current > 5000) return false;
  if ((first - current).abs() <= 50) return true;
  // The strongest bin can alternate between the first three harmonics.
  for (var a = 1; a <= 3; a++) {
    for (var b = 1; b <= 3; b++) {
      if (a != b && (first / a - current / b).abs() <= 25) return true;
    }
  }
  return false;
}

AudioAnalysis analyzeAudio(List<AudioFrame> frames) {
  final valid = frames
      .where(
        (f) =>
            f.time.isFinite &&
            f.rms.isFinite &&
            f.tone.isFinite &&
            f.rms >= 0 &&
            f.tone >= 0,
      )
      .toList();
  final levels = valid.map((f) => f.rms).toList()..sort();
  final noiseFloor = levels.isEmpty
      ? 0.0
      : levels[(levels.length * .2).floor()];
  final minimumRms = math.max(.0002, noiseFloor * .35);
  final beeps = <BeepCandidate>[];
  var i = 0;
  while (i < valid.length) {
    final first = valid[i];
    final frequency = first.frequencyHz;
    final hasFrequency =
        frequency != null &&
        frequency.isFinite &&
        frequency >= 1250 &&
        frequency <= 5000;
    if (first.rms < minimumRms || first.tone < (hasFrequency ? .18 : .45)) {
      i++;
      continue;
    }
    var last = i;
    var count = 0;
    var sumTone = 0.0;
    var maxTone = 0.0;
    var gap = 0;
    var end = i;
    for (; end < valid.length; end++) {
      final f = valid[end];
      if (end > i &&
          (f.time <= valid[end - 1].time ||
              f.time - valid[end - 1].time > .031)) {
        break;
      }
      final stable = hasFrequency
          ? f.frequencyHz != null && _sameToneFamily(frequency, f.frequencyHz!)
          : f.frequencyHz == null;
      final tonal =
          stable && f.rms >= minimumRms && f.tone >= (hasFrequency ? .05 : .45);
      if (tonal) {
        last = end;
        count++;
        gap = 0;
        sumTone += f.tone;
        maxTone = math.max(maxTone, f.tone);
      } else if (++gap > (hasFrequency ? 2 : 0)) {
        break;
      }
    }
    final duration = valid[last].time - first.time + .02;
    final stability = count / (last - i + 1);
    final meanTone = count == 0 ? 0.0 : sumTone / count;
    if (duration >= (hasFrequency ? .18 - 1e-6 : .08 - 1e-6) &&
        duration <= 1.5 &&
        stability >= .8 &&
        meanTone >= (hasFrequency ? .22 : .45) &&
        // Weak narrow-band tails need longer support than a strong timer tone.
        (!hasFrequency || duration >= .24 - 1e-6 || meanTone >= .35) &&
        maxTone >= (hasFrequency ? .35 : .45)) {
      beeps.add(
        BeepCandidate(
          time: first.time,
          duration: duration,
          frequencyHz: hasFrequency ? frequency : null,
          atBoundary: i == 0,
          confidence:
              (i == 0 ? .5 : 1) *
              (.55 * meanTone +
                      .25 * stability +
                      .2 * (duration / .4).clamp(0, 1))
                  .clamp(0, 1)
                  .toDouble(),
        ),
      );
      i = last + 1;
    } else {
      i = duration > 1.5 ? last + 1 : i + 1;
    }
  }
  final shots = <double>[];
  var baseline = .005;
  for (final frame in valid) {
    final tonal = beeps.any(
      (b) => frame.time >= b.time && frame.time < b.time + b.duration,
    );
    if (!tonal &&
        frame.rms > .06 &&
        frame.rms > baseline * 4 &&
        (shots.isEmpty || frame.time - shots.last > .15)) {
      shots.add(frame.time);
    }
    baseline = baseline * .94 + frame.rms * .06;
  }
  return AudioAnalysis(
    beep: beeps.isEmpty || beeps.first.atBoundary ? null : beeps.first.time,
    beepCandidates: beeps,
    shotCandidates: shots,
  );
}

/// Timer times stay authoritative; video marks and optional candidates use file timestamps.
List<double> videoShotTimes({
  required double start,
  List<double>? timerTimes,
  List<double> markers = const [],
  List<double> candidates = const [],
}) {
  if (timerTimes != null) return List<double>.of(timerTimes);
  final times = [
    ...markers,
    ...candidates,
  ].where((time) => time >= start).map((time) => time - start).toList()..sort();
  final unique = <double>[];
  for (final time in times) {
    if (unique.isEmpty || time - unique.last >= .01) unique.add(time);
  }
  return unique;
}

int videoShotIndex(List<double> times, double elapsed) {
  if (elapsed < 0) return -1;
  return times.lastIndexWhere((time) => time <= elapsed);
}

double videoSplit(List<double> times, int index) =>
    times[index] - (index == 0 ? 0 : times[index - 1]);
