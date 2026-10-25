part of 'timer_protocol.dart';

/// Interoperability records; hardware qualification is listed in timer-support.md.
class _AdditionalDecoder implements TimerDecoder {
  _AdditionalDecoder(this.profile);
  final String profile;
  String _text = '';
  int? _session;
  int _index = -1, _time = -1;
  bool _stopped = false;

  void _begin(int? session, List<TimerEvent> out) {
    if (session == null ||
        session < 0 ||
        session > 9007199254740991 ||
        session == _session) {
      return;
    }
    _session = session;
    _index = _time = -1;
    _stopped = false;
    out.add(TimerEvent(TimerEventKind.start, profile, sessionId: session));
  }

  void _hit(int? session, int? index, int? time, List<TimerEvent> out) {
    if (_stopped ||
        session == null ||
        session != _session ||
        index == null ||
        index < 0 ||
        index <= _index ||
        time == null ||
        time <= 0 ||
        time <= _time ||
        time > 9007199254740991) {
      return;
    }
    _index = index;
    _time = time;
    out.add(
      TimerEvent(
        TimerEventKind.shot,
        profile,
        sessionId: session,
        shotIndex: index,
        milliseconds: time,
      ),
    );
  }

  void _end(int? session, List<TimerEvent> out) {
    if (session == null || session != _session || _stopped) return;
    _stopped = true;
    out.add(TimerEvent(TimerEventKind.stop, profile, sessionId: session));
  }

  @override
  List<TimerEvent> add(List<int> bytes) {
    final out = <TimerEvent>[];
    if (bytes.length > 4096 || bytes.any((b) => b < 0 || b > 255)) {
      _text = '';
      return out;
    }
    if (profile == 'amg-nus') {
      int number(int offset) => bytes[offset] * 256 + bytes[offset + 1];
      if (bytes.length == 11 && bytes[0] == 3) {
        if (bytes[1] == 1) _begin(number(9), out);
        if (bytes[1] == 0) _end(number(9), out);
      } else if ((bytes.length == 14 && bytes[0] == 1) ||
          (bytes.length == 16 && bytes[0] == 2)) {
        final small = bytes[0] == 1, session = number(bytes[0] == 1 ? 12 : 14);
        if ((bytes[1] & 4) != 0) _begin(session, out);
        _hit(
          session,
          small ? bytes[2] : number(2),
          number(small ? 4 : 6) * 10,
          out,
        );
        if ((bytes[1] & 8) != 0) _end(session, out);
      }
      return out;
    }
    if (bytes.any((b) => b > 127)) {
      _text = '';
      return out;
    }
    final text = String.fromCharCodes(bytes);
    if (profile == 'rangetech') {
      final begin = RegExp(r'^![^:]+:BEEP\|(\d+)$').firstMatch(text);
      if (begin != null) _begin(int.tryParse(begin[1]!), out);
      if (RegExp(r'^![^:]+:BUTTONUP$').hasMatch(text)) _end(_session, out);
      final shot = RegExp(r'^!SHOT(\d+)\|(\d+)\|(\d+)$').firstMatch(text);
      if (shot != null) {
        _hit(
          int.tryParse(shot[3]!),
          int.tryParse(shot[2]!),
          int.tryParse(shot[1]!),
          out,
        );
      }
      return out;
    }
    _text += text;
    if (_text.length > 4096) {
      _text = '';
      return out;
    }
    var depth = 0, start = -1, used = 0;
    var quoted = false, escaped = false;
    for (var i = 0; i < _text.length; i++) {
      final c = _text[i];
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == '\\') {
          escaped = true;
        } else if (c == '"') {
          quoted = false;
        }
        continue;
      }
      if (c == '"' && depth > 0) {
        quoted = true;
        continue;
      }
      if (c == '{') {
        if (depth == 0) start = i;
        depth++;
      }
      if (c == '}' && depth > 0 && --depth == 0) {
        used = i + 1;
        try {
          final m = jsonDecode(_text.substring(start, i + 1));
          if (m is! Map) continue;
          final session = m['start'] is int ? m['start'] as int : null;
          if (m['t'] == 'string-started') _begin(session, out);
          if (m['t'] == 'string-stopped') _end(session, out);
          if (m['t'] == 'shot') {
            _hit(
              session,
              m['index'] is int ? m['index'] as int : null,
              m['timeInMs'] is int ? m['timeInMs'] as int : null,
              out,
            );
          }
        } on FormatException {
          /* Ignore malformed records; never fabricate a shot. */
        }
      }
    }
    _text = _text.substring(
      used != 0
          ? used
          : start < 0
          ? _text.length
          : start,
    );
    return out;
  }
}
