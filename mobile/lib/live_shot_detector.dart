import 'dart:math' as math;

class MicFrame {
  const MicFrame({
    required this.at,
    required this.rms,
    required this.peak,
    this.toneRatio = 0,
    this.clipped = false,
  });
  final double at, rms, peak, toneRatio;
  final bool clipped;
  factory MicFrame.fromMap(Map<dynamic, dynamic> map) {
    double number(String key) {
      final value = map[key];
      if (value is! num || !value.isFinite) {
        throw FormatException('Invalid microphone $key');
      }
      return value.toDouble();
    }

    final frame = MicFrame(
      at: number('at'),
      rms: number('rms'),
      peak: number('peak'),
      toneRatio: number('toneRatio'),
      clipped: map['clipped'] == true,
    );
    if (frame.at < 0 ||
        [frame.rms, frame.peak, frame.toneRatio].any((v) => v < 0 || v > 1)) {
      throw const FormatException('Invalid microphone range');
    }
    return frame;
  }
}

/// Foreground acoustic detector. Phone mic processing/latency requires field calibration.
class LiveShotDetector {
  LiveShotDetector({
    double sensitivity = 50,
    double minInterval = .10,
    bool echoSuppression = true,
    double echoWindow = .18,
  }) {
    configure(
      sensitivity: sensitivity,
      minInterval: minInterval,
      echoSuppression: echoSuppression,
      echoWindow: echoWindow,
    );
  }
  late double _threshold, _minInterval, _echoWindow;
  double _referencePeak = 0;
  bool _echoSuppression = true;
  double? _start, _lastFrame, _lastShot, _quietSince;
  bool _armed = true;
  double get threshold => _threshold;
  void configure({
    required double sensitivity,
    required double minInterval,
    bool echoSuppression = true,
    double echoWindow = .18,
  }) {
    if (!sensitivity.isFinite ||
        sensitivity < 0 ||
        sensitivity > 100 ||
        !minInterval.isFinite ||
        minInterval < .06 ||
        minInterval > .30 ||
        !echoWindow.isFinite ||
        echoWindow < .08 ||
        echoWindow > .4) {
      throw ArgumentError('Invalid detector settings');
    }
    _threshold = math.pow(10, (-8 - .40 * sensitivity) / 20).toDouble();
    _minInterval = minInterval;
    _echoWindow = echoWindow;
    _echoSuppression = echoSuppression;
  }

  void start(double at) {
    if (!at.isFinite || at < 0) throw ArgumentError('Invalid start');
    _start = at;
    _lastFrame = null;
    _lastShot = null;
    _quietSince = null;
    _armed = true;
    _referencePeak = 0;
  }

  void stop() {
    _start = null;
  }

  double? add(MicFrame frame) {
    if (!frame.at.isFinite ||
        !frame.rms.isFinite ||
        !frame.peak.isFinite ||
        !frame.toneRatio.isFinite ||
        frame.at < 0 ||
        [frame.rms, frame.peak, frame.toneRatio].any((v) => v < 0 || v > 1)) {
      return null;
    }
    final start = _start;
    if (start == null ||
        frame.at < start ||
        (_lastFrame != null && frame.at <= _lastFrame!)) {
      return null;
    }
    _lastFrame = frame.at;
    // Ignore signal onset and sustained own tone; broadband impulses remain eligible.
    if (frame.at - start < .08 || frame.toneRatio >= .65) {
      _quietSince = null;
      return null;
    }
    if (_lastShot != null && frame.at - _lastShot! < .03) {
      _referencePeak = math.max(_referencePeak, frame.peak);
    }
    final quiet = frame.peak < _threshold * .60 && frame.rms < _threshold * .15;
    if (quiet) {
      _quietSince ??= frame.at;
      if (frame.at - _quietSince! >= .019) _armed = true;
      return null;
    }
    _quietSince = null;
    final impulse = frame.peak >= _threshold && frame.rms >= _threshold * .15;
    if (!impulse || !_armed) return null;
    _armed = false;
    if (_lastShot != null && frame.at - _lastShot! < _minInterval) return null;
    // Quieter delayed copies are likely echoes; keep comparable fast impulses eligible.
    if (_echoSuppression &&
        _lastShot != null &&
        frame.at - _lastShot! < _echoWindow &&
        frame.peak < _referencePeak * .65) {
      return null;
    }
    _referencePeak = frame.peak;
    _lastShot = frame.at;
    return frame.at - start;
  }
}
