/// Projects sparse player position samples onto one monotonic time base.
class PlaybackClock {
  double? _position;
  double _at = 0, _speed = 1;
  bool _playing = false, _buffering = false;

  void observe({
    required double position,
    required bool playing,
    required bool buffering,
    required double speed,
    required double now,
  }) {
    if (!position.isFinite || !now.isFinite || !speed.isFinite || speed <= 0) {
      throw ArgumentError(
        'Playback samples and time must be finite; speed must be positive',
      );
    }
    // Repeated controller notifications do not represent new position samples.
    if (_position == position &&
        _playing == playing &&
        _buffering == buffering &&
        _speed == speed) {
      return;
    }
    _position = position;
    _at = now;
    _playing = playing;
    _buffering = buffering;
    _speed = speed;
  }

  double projectedPosition(double now) {
    if (!now.isFinite) throw ArgumentError.value(now, 'now', 'Must be finite');
    final position = _position;
    if (position == null) return 0;
    if (!_playing || _buffering) return position;
    return position + (now - _at).clamp(0.0, double.infinity) * _speed;
  }

  /// Call when replacing a player or explicitly seeking to the same position.
  void reset() {
    _position = null;
  }
}
