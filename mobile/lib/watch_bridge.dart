import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'timer_session.dart';

enum WatchPhase { idle, preparing, running, finished, unavailable }

/// Compact v1 snapshot. Milliseconds, little endian.
Uint8List watchPacket({
  required int run,
  required int revision,
  required WatchPhase phase,
  required List<double> times,
  bool phone = false,
  bool controllable = false,
  bool failed = false,
}) {
  final b = ByteData(20);
  b.setUint8(0, 1);
  b.setUint8(
    1,
    phase.index |
        (phone ? 16 : 0) |
        (controllable ? 32 : 0) |
        (failed ? 64 : 0),
  );
  b.setUint16(2, times.length, Endian.little);
  b.setUint32(4, run, Endian.little);
  b.setUint32(8, revision, Endian.little);
  b.setUint32(
    12,
    times.isEmpty ? 0 : (times.last * 1000).round(),
    Endian.little,
  );
  b.setUint32(
    16,
    times.length < 2
        ? 0xffffffff
        : ((times.last - times[times.length - 2]) * 1000).round(),
    Endian.little,
  );
  return b.buffer.asUint8List();
}

class WatchBridge extends ChangeNotifier {
  WatchBridge(this.session) {
    session.addListener(_externalChanged);
  }
  static const channel = MethodChannel('ipsc/watch');
  static const events = EventChannel('ipsc/watch-events');
  final TimerSession session;
  bool enabled = false, busy = false, phone = false, approved = false;
  bool _disposed = false, _failed = false;
  bool _commandBusy = false;
  String status = 'Часы отключены';
  String? peer;
  int? peerCode;
  int run = Random.secure().nextInt(0x7fffffff) + 1, revision = 0;
  String? _externalKey;
  WatchPhase phase = WatchPhase.unavailable;
  List<double> times = [];
  bool _phoneCanControl = false;
  bool automaticSource = true;
  bool _foreground = true;
  Future<void> Function()? _phoneLauncher;

  void attachPhoneLauncher(Future<void> Function() launcher) {
    _phoneLauncher = launcher;
    _externalChanged();
  }

  void foreground(bool value) {
    _foreground = value;
    if (phone && _phoneCommand == null) {
      phase = value && _phoneLauncher != null
          ? WatchPhase.idle
          : WatchPhase.unavailable;
    }
    _publish();
    _notify();
  }

  Future<void> Function(bool start, int? delayMs)? _phoneCommand;
  StreamSubscription<dynamic>? _events;
  Uint8List? _lastPublished;
  Future<void> _writes = Future.value();
  bool get controllable =>
      phone &&
      _foreground &&
      ((_phoneCommand != null && _phoneCanControl) ||
          (_phoneCommand == null && _phoneLauncher != null));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restore() async {
    try {
      final enabledBefore =
          await channel.invokeMethod<bool>('preferences') ?? false;
      if (!_disposed && enabledBefore && !enabled && !busy) await start();
    } catch (_) {
      /* Older native builds have no remembered pairing. */
    }
  }

  Future<void> forget() async {
    if (busy) return;
    try {
      await channel.invokeMethod<void>('forget');
      approved = false;
      peer = null;
      peerCode = null;
      status = 'Часы забыты. Подключите и подтвердите их заново.';
      _notify();
    } catch (e) {
      status = 'Не удалось забыть часы: $e';
      _notify();
    }
  }

  Future<void> start() async {
    if (busy || enabled) return;
    busy = true;
    _notify();
    try {
      final sdk =
          await const MethodChannel('pace/audio')
              .invokeMethod<int>('androidSdk') ??
          31;
      if (sdk >= 31) {
        final grants = await [Permission.bluetoothConnect].request();
        if (grants.values.any((s) => !s.isGranted)) {
          throw StateError('Разрешите устройства поблизости');
        }
      }
      _events = events.receiveBroadcastStream().listen(
        _event,
        onError: (Object e) {
          status = 'Ошибка связи: $e';
          _notify();
        },
      );
      await channel.invokeMethod<void>('start');
      enabled = true;
      session.watchBridgeRunning = true;
      await session.refreshBackgroundService();
      status = approved
          ? 'Часы подключены автоматически'
          : peer == null
          ? 'Откройте приложение часов через Zepp'
          : 'Подтвердите свои часы на этом экране';
      _lastPublished = null;
      _externalChanged();
      _publish();
    } catch (e) {
      status = 'Не удалось включить часы: $e';
      await _events?.cancel();
      _events = null;
      try {
        await channel.invokeMethod<void>('stop');
      } catch (_) {}
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> stop() async {
    if (busy) return;
    busy = true;
    enabled = false;
    approved = false;
    peer = null;
    try {
      await channel.invokeMethod<void>('stop');
      status = 'Часы отключены';
    } catch (e) {
      status = 'Ошибка отключения: $e';
    }
    await _events?.cancel();
    _events = null;
    session.watchBridgeRunning = false;
    await session.refreshBackgroundService();
    busy = false;
    _notify();
  }

  Future<void> approve() async {
    final candidate = peer;
    if (!enabled || candidate == null) return;
    try {
      await channel.invokeMethod<void>('approve', {
        'peer': candidate,
        'code': peerCode,
      });
      approved = true;
      status = 'Часы подключены';
      _notify();
    } catch (e) {
      status = 'Подтверждение не удалось: $e';
      _notify();
    }
  }

  void selectPhone(bool value) {
    if (phase == WatchPhase.running || phase == WatchPhase.preparing) return;
    automaticSource = false;
    phone = value;
    _externalKey = null;
    _newRun();
    times = [];
    phase = WatchPhase.unavailable;
    if (!phone) _externalChanged();
    _publish();
    _notify();
  }

  void attachPhone(Future<void> Function(bool, int?) command) {
    _phoneCommand = command;
  }

  void detachPhone() {
    _phoneCommand = null;
    _phoneCanControl = false;
    if (phone) {
      _newRun();
      phase = _foreground && _phoneLauncher != null
          ? WatchPhase.idle
          : WatchPhase.unavailable;
      _publish();
      _notify();
    }
  }

  void phoneState(
    WatchPhase state,
    List<double> shots, {
    required bool canControl,
    bool newRun = false,
    bool failed = false,
  }) {
    _phoneCanControl = canControl;
    if (!phone) return;
    if (newRun) _newRun();
    phase = state;
    times = List.of(shots);
    _failed = failed;
    _publish();
    _notify();
  }

  void _newRun() {
    run = (run + 1) & 0xffffffff;
    _failed = false;
  }

  void _externalChanged() {
    if (_disposed) return;
    if (automaticSource) {
      if (phone && [WatchPhase.preparing, WatchPhase.running].contains(phase)) {
        return;
      }
      final connected = session.links.values.where((l) => l.device.isConnected);
      final selected = session.selected;
      final external = selected != null && selected.device.isConnected
          ? selected
          : connected.firstOrNull;
      if (external == null) {
        if (!phone) {
          phone = true;
          _externalKey = null;
          _newRun();
          times = [];
          phase = controllable ? WatchPhase.idle : WatchPhase.unavailable;
        }
        _publish();
        _notify();
        return;
      }
      if (session.selectedId != external.device.remoteId.str) {
        session.select(external.device.remoteId.str);
        return;
      }
      if (phone) {
        phone = false;
        _externalKey = null;
      }
    }
    if (phone) return;
    final link = session.selected;
    final series = link?.active ?? link?.pending.lastOrNull;
    final key = '${session.selectedId}/${series?.id}';
    if (key != _externalKey) {
      _externalKey = key;
      _newRun();
    }
    times = List.of(series?.times ?? []);
    phase =
        link == null || !link.device.isConnected || link.notifications == null
        ? WatchPhase.unavailable
        : series == null
        ? WatchPhase.idle
        : series.partial
        ? WatchPhase.unavailable
        : series.complete
        ? WatchPhase.finished
        : WatchPhase.running;
    _publish();
    _notify();
  }

  void _event(dynamic raw) {
    if (_disposed || raw is! Map) return;
    switch (raw['event']) {
      case 'trusted':
        peer = raw['peer'] as String?;
        peerCode = null;
        approved = true;
        status = 'Часы подключены автоматически';
      case 'peer':
        peer = raw['peer'] as String?;
        peerCode = raw['code'] as int?;
        approved = false;
        status = 'Подтвердите свои часы на этом экране';
      case 'disconnected':
        peer = null;
        approved = false;
        status = 'Связь потеряна. Подключитесь с часов снова';
      case 'error':
        status = 'Bluetooth: ${raw['message']}';
      case 'command':
        unawaited(handleCommand(raw));
    }
    _notify();
  }

  @visibleForTesting
  Future<void> handleCommand(Map<dynamic, dynamic> raw) async {
    if (!enabled || !approved || _disposed || _commandBusy) return;
    if (raw['run'] != run) {
      _publish(force: true);
      return;
    }
    if (phone &&
        raw['run'] == run &&
        raw['op'] == 2 &&
        phase == WatchPhase.finished) {
      _publish(force: true);
      return;
    }
    final delayMs = raw['delayMs'];
    if (delayMs != null &&
        (delayMs is! int || delayMs < 0 || delayMs > 60000)) {
      _failed = true;
      _publish(force: true);
      return;
    }
    if (!controllable ||
        raw['op'] is! int ||
        ![1, 2].contains(raw['op']) ||
        (raw['op'] == 1 &&
            (phase == WatchPhase.running || phase == WatchPhase.preparing)) ||
        (raw['op'] == 2 &&
            phase != WatchPhase.running &&
            phase != WatchPhase.preparing)) {
      _failed = true;
      _publish(force: true);
      return;
    }
    try {
      _commandBusy = true;
      _failed = false;
      if (raw['op'] == 1 && _phoneCommand == null && _phoneLauncher != null) {
        await _phoneLauncher!();
        for (
          var attempt = 0;
          attempt < 100 &&
              _foreground &&
              (_phoneCommand == null || !_phoneCanControl);
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      if (!_foreground || _phoneCommand == null || !_phoneCanControl) {
        throw StateError('Откройте готовый телефонный таймер');
      }
      await _phoneCommand!(
        raw['op'] == 1,
        raw['op'] == 1 ? delayMs as int? : null,
      );
    } catch (e) {
      _failed = true;
      status = 'Команда часов: $e';
    } finally {
      _commandBusy = false;
    }
    _publish(force: true);
    _notify();
  }

  void _publish({bool force = false}) {
    if (!enabled || _disposed) return;
    final candidate = watchPacket(
      run: run,
      revision: 0,
      phase: phase,
      times: times,
      phone: phone,
      controllable: controllable,
      failed: _failed,
    );
    if (!force && listEquals(_lastPublished, candidate)) return;
    _lastPublished = candidate;
    revision = (revision + 1) & 0xffffffff;
    final bytes = Uint8List.fromList(candidate);
    ByteData.sublistView(bytes).setUint32(8, revision, Endian.little);
    _writes = _writes
        .catchError((Object _) {})
        .then((_) async {
          if (enabled && !_disposed) {
            await channel.invokeMethod<void>('publish', bytes);
          }
        })
        .catchError((Object e) {
          status = 'Ошибка передачи: $e';
          _notify();
        });
  }

  @override
  void dispose() {
    session.removeListener(_externalChanged);
    _disposed = true;
    enabled = false;
    session.watchBridgeRunning = false;
    unawaited(_events?.cancel());
    unawaited(channel.invokeMethod<void>('close').catchError((Object _) {}));
    super.dispose();
  }
}
