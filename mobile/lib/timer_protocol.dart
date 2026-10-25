import 'dart:convert';

part 'timer_additional.dart';

enum TimerEventKind { start, shot, stop }

class TimerEvent {
  const TimerEvent(
    this.kind,
    this.profileId, {
    this.centiseconds,
    this.milliseconds,
    this.shotIndex,
    this.sessionId,
  });
  final TimerEventKind kind;
  final String profileId;
  final int? centiseconds;
  final int? milliseconds;
  final int? shotIndex;
  final int? sessionId;
  double? get seconds => milliseconds != null
      ? milliseconds! / 1000
      : centiseconds == null
      ? null
      : centiseconds! / 100;
}

abstract class TimerDecoder {
  List<TimerEvent> add(List<int> bytes);
}

class TimerProfile {
  const TimerProfile(
    this.id,
    this.label,
    this.createDecoder, {
    this.service,
    this.notify,
    this.write,
  });
  final String id;
  final String label;
  final TimerDecoder Function() createDecoder;
  final String? service, notify, write;
}

/// Automatic detection requires a valid framed packet; unknown formats stay raw.
class TimerProtocols {
  static const rawId = 'raw';
  static const autoId = 'auto';
  static const legacyId = 'special-pie-legacy-experimental';
  static const sgId = 'sg-v3';
  static final profiles = <TimerProfile>[
    TimerProfile(autoId, 'Автоматически — ожидаем данные', _LegacyDecoder.new),
    TimerProfile(rawId, 'Raw: неизвестный протокол', _RawDecoder.new),
    TimerProfile(
      legacyId,
      'Special Pie legacy — экспериментально',
      _LegacyDecoder.new,
      service: 'fff0',
      notify: 'fff1',
      write: 'fff2',
    ),
    TimerProfile(
      sgId,
      'SG Sport / GO — API 3 (без проверки устройства)',
      _SgDecoder.new,
      service: '7520ffff-14d2-4cda-8b6b-697c554c9311',
      notify: '75200001-14d2-4cda-8b6b-697c554c9311',
      write: '75200000-14d2-4cda-8b6b-697c554c9311',
    ),
    TimerProfile(
      'protimer-v2',
      'ProTimer BT / PT Link v2 — экспериментально',
      () => _AdditionalDecoder('protimer-v2'),
      service: '26cc3fc0-6241-f5b4-5347-63a3097f6764',
      notify: '26cc3fc1-6241-f5b4-5347-63a3097f6764',
      write: '26cc3fc2-6241-f5b4-5347-63a3097f6764',
    ),
    TimerProfile(
      'rangetech',
      'RangeTech — экспериментально',
      () => _AdditionalDecoder('rangetech'),
      service: '958de860-ee25-4627-9cf8-7821b18cbd29',
      notify: '958de862-ee25-4627-9cf8-7821b18cbd29',
      write: '958de861-ee25-4627-9cf8-7821b18cbd29',
    ),
    TimerProfile(
      'amg-nus',
      'AMG COMM / PS / SK — экспериментально',
      () => _AdditionalDecoder('amg-nus'),
      service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      notify: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
      write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
    ),
  ];

  static TimerProfile? profile(String id) =>
      profiles.where((p) => p.id == id).firstOrNull;

  // Interoperability: Special Pie control frames use no session byte.
  static List<int> controlPacket(String profile, bool start) {
    if (profile == sgId) return [1, start ? 0 : 3];
    if (profile == 'protimer-v2') {
      return ascii.encode(
        jsonEncode({'t': start ? 'start-string' : 'stop-string'}),
      );
    }
    if (profile == 'rangetech') {
      return ascii.encode(start ? 'B000000' : 'C000000');
    }
    if (profile == 'amg-nus') {
      return ascii.encode(start ? 'COM START' : 'COM STOP');
    }
    if (profile != legacyId) {
      throw UnsupportedError('Нет команды управления этим протоколом');
    }
    return [0xf8, 0xf9, start ? 0x34 : 0x18, 0xf9, 0xf8];
  }

  static TimerDecoder decoder(String id) => profiles
      .firstWhere(
        (profile) => profile.id == id,
        orElse: () => profiles.firstWhere((p) => p.id == rawId),
      )
      .createDecoder();
}

/// SG BLE API 3: big endian, length-prefixed event stream; ACK is not an event.
class _SgDecoder implements TimerDecoder {
  final _buffer = <int>[];
  int? _session;
  int _lastIndex = -1, _lastTime = -1;
  bool _stopped = false;
  @override
  List<TimerEvent> add(List<int> bytes) {
    final events = <TimerEvent>[];
    if (bytes.length > 4096 || bytes.any((b) => b < 0 || b > 255)) {
      _buffer.clear();
      return events;
    }
    _buffer.addAll(bytes);
    if (_buffer.length > 4096) {
      _buffer.clear();
      return events;
    }
    while (_buffer.length >= 2) {
      if (![2, 5, 7, 11].contains(_buffer[0])) {
        _buffer.removeAt(0);
        continue;
      }
      final length = _buffer[0] + 1;
      if (_buffer.length < length) break;
      final f = _buffer.sublist(0, length);
      _buffer.removeRange(0, length);
      if (length < 6) continue;
      int number(int offset, int size) =>
          f.sublist(offset, offset + size).fold(0, (v, b) => v * 256 + b);
      final session = number(2, 4), type = f[1];
      if (type == 0 && length == 8) {
        if (_session == session) continue;
        _session = session;
        _lastIndex = _lastTime = -1;
        _stopped = false;
        events.add(
          TimerEvent(
            TimerEventKind.start,
            TimerProtocols.sgId,
            sessionId: session,
          ),
        );
      } else if (type == 3 && length == 8 && session == _session && !_stopped) {
        _stopped = true;
        events.add(
          TimerEvent(
            TimerEventKind.stop,
            TimerProtocols.sgId,
            sessionId: session,
          ),
        );
      } else if (type == 4 &&
          length == 12 &&
          session == _session &&
          !_stopped) {
        final index = number(6, 2), time = number(8, 4);
        if (index <= _lastIndex || time <= 0 || time <= _lastTime) continue;
        _lastIndex = index;
        _lastTime = time;
        events.add(
          TimerEvent(
            TimerEventKind.shot,
            TimerProtocols.sgId,
            sessionId: session,
            shotIndex: index,
            milliseconds: time,
          ),
        );
      }
    }
    return events;
  }
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
