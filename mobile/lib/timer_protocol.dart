enum TimerEventKind { start, shot, stop }

class TimerEvent {
  const TimerEvent(
    this.kind,
    this.profileId, {
    this.centiseconds,
    this.shotIndex,
    this.sessionId,
  });
  final TimerEventKind kind;
  final String profileId;
  final int? centiseconds;
  final int? shotIndex;
  final int? sessionId;
  double? get seconds => centiseconds == null ? null : centiseconds! / 100;
}

abstract class TimerDecoder {
  List<TimerEvent> add(List<int> bytes);
}

class TimerProfile {
  const TimerProfile(this.id, this.label, this.createDecoder);
  final String id;
  final String label;
  final TimerDecoder Function() createDecoder;
}

/// Automatic detection requires a valid framed packet; unknown formats stay raw.
class TimerProtocols {
  static const rawId = 'raw';
  static const autoId = 'auto';
  static const legacyId = 'special-pie-legacy-experimental';
  static final profiles = <TimerProfile>[
    TimerProfile(autoId, 'Автоматически — ожидаем данные', _LegacyDecoder.new),
    TimerProfile(rawId, 'Raw: неизвестный протокол', _RawDecoder.new),
    TimerProfile(
      legacyId,
      'Special Pie legacy — экспериментально',
      _LegacyDecoder.new,
    ),
  ];

  static TimerDecoder decoder(String id) => profiles
      .firstWhere(
        (profile) => profile.id == id,
        orElse: () => profiles.firstWhere((p) => p.id == rawId),
      )
      .createDecoder();
}

class _RawDecoder implements TimerDecoder {
  @override
  List<TimerEvent> add(List<int> bytes) => [];
}

/// Candidate format, not qualified on the user's firmware. Source:
/// github.com/jkesseler/sg-timer-led-display/blob/de8e30c63daeadc0d116c14b4bc56b89c8d0d8a7/docs/timer-protocols/special-pie-ble.md
class _LegacyDecoder implements TimerDecoder {
  final _buffer = <int>[];
  int? _session;
  int _lastIndex = -1;
  int _lastTime = -1;

  @override
  List<TimerEvent> add(List<int> bytes) {
    final events = <TimerEvent>[];
    if (bytes.length > 4096 || bytes.any((b) => b < 0 || b > 255)) {
      _buffer.clear();
      return events;
    }
    _buffer.addAll(bytes);
    while (_buffer.length >= 3) {
      if (_buffer[0] != 0xf8 || _buffer[1] != 0xf9) {
        _buffer.removeAt(0);
        continue;
      }
      final type = _buffer[2];
      final length = type == 0x36 ? 10 : (type == 0x34 || type == 0x18 ? 6 : 0);
      if (length == 0) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < length) break;
      if (_buffer[length - 2] != 0xf9 || _buffer[length - 1] != 0xf8) {
        _buffer.removeAt(0);
        continue;
      }
      final frame = _buffer.sublist(0, length);
      _buffer.removeRange(0, length);
      if (type == 0x34) {
        if (_session == frame[3]) continue;
        _session = frame[3];
        _lastIndex = _lastTime = -1;
        events.add(
          TimerEvent(
            TimerEventKind.start,
            TimerProtocols.legacyId,
            sessionId: _session,
          ),
        );
      } else if (type == 0x18) {
        if (_session != frame[3]) continue;
        events.add(
          TimerEvent(
            TimerEventKind.stop,
            TimerProtocols.legacyId,
            sessionId: _session,
          ),
        );
        _session = null;
      } else if (_session != null && frame[3] == 0 && frame[5] < 100) {
        final time = frame[4] * 100 + frame[5];
        final index = frame[6];
        // Preserve wire index: public evidence conflicts on zero/one-based numbering.
        if (index <= _lastIndex || time <= 0 || time <= _lastTime) continue;
        _lastIndex = index;
        _lastTime = time;
        events.add(
          TimerEvent(
            TimerEventKind.shot,
            TimerProtocols.legacyId,
            centiseconds: time,
            shotIndex: index,
            sessionId: _session,
          ),
        );
      }
    }
    return events;
  }
}
