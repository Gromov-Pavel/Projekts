import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'timer_protocol.dart';
import 'timer_preferences.dart';

String timerErrorMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('permission') || text.contains('securityexception')) {
    return 'Нет разрешения на устройства поблизости. Откройте настройки IPSC тренировОчка → Разрешения и разрешите Bluetooth.';
  }
  if (text.contains('adapter') ||
      text.contains('bluetooth is off') ||
      text.contains('bluetooth must be turned on')) {
    return 'Bluetooth выключен. Включите его на телефоне и повторите поиск.';
  }
  if (text.contains('timeout') || text.contains('timed out')) {
    return 'Таймер не ответил. Поднесите его ближе, проверьте Bluetooth на таймере и отключите его от другого приложения.';
  }
  return 'Не удалось выполнить действие. Повторите попытку. Текст ошибки сохранён в подробностях ниже.';
}

class TimerPendingSeries {
  TimerPendingSeries(this.id, this.source);
  final String id;
  final String source;
  final times = <double>[];
  bool complete = false;
  bool partial = false;
  bool saved = false;
  bool saving = false;
}

class TimerLink {
  TimerLink(this.device);
  final BluetoothDevice device;
  List<BluetoothService> services = [];
  StreamSubscription<List<int>>? notifications;
  StreamSubscription<BluetoothConnectionState>? connection;
  String profile = TimerProtocols.rawId;
  TimerDecoder decoder = TimerProtocols.decoder(TimerProtocols.rawId);
  final pending = <TimerPendingSeries>[];
  TimerPendingSeries? active;
  bool acceptedLegacy = false;
  String status = 'Подключение…';
}

class TimerSession extends ChangeNotifier {
  final Future<bool> Function(List<double>, String) onImport;
  bool _disposed = false;
  bool get mounted => !_disposed;
  String? selectedId;
  bool serviceRunning = false;
  bool watchBridgeRunning = false;
  String backgroundStatus = 'Фоновый приём ещё не запущен.';
  final String _sessionId = DateTime.now().microsecondsSinceEpoch.toString();
  void _change(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  final links = <String, TimerLink>{};
  final _records = <Map<String, dynamic>>[];
  List<ScanResult> found = [];
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanningSubscription;
  bool scanning = false;
  bool searched = false;
  String? lastError;
  int diagnosticBytes = 0;
  bool full = false;
  bool busy = false;
  int _nextSeriesId = 0;
  String message = '';
  int get connectedCount =>
      links.values.where((link) => link.device.isConnected).length;

  TimerSession({required this.onImport});

  final preferences = TimerPreferences();
  File? _preferencesFile;
  Future<void> _preferencesQueue = Future.value();
  Timer? _reconnectTimer;
  bool _autoConnecting = false;
  bool _restored = false;
  final _paused = <String>{};

  Future<void> restoreKnownTimers() async {
    if (_restored || !mounted) return;
    _restored = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      _preferencesFile = File('${dir.path}/known-timers.json');
      if (await _preferencesFile!.exists()) {
        preferences.read(await _preferencesFile!.readAsString());
      }
      if (!mounted) return;
      selectedId = preferences.selectedId;
      for (final timer in preferences.ordered) {
        links
                .putIfAbsent(
                  timer.id,
                  () => TimerLink(BluetoothDevice.fromId(timer.id)),
                )
                .status =
            'Сохранённый таймер';
      }
      notifyListeners();
      _reconnectTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _autoScan(),
      );
      await _autoScan();
    } catch (e) {
      _report('Загрузка сохранённых таймеров', e);
    }
  }

  Future<void> _savePreferences() {
    _preferencesQueue = _preferencesQueue.then((_) async {
      try {
        final file = _preferencesFile;
        if (file != null) await preferences.save(file);
      } catch (e) {
        _report('Сохранение таймеров', e);
      }
    });
    return _preferencesQueue;
  }

  Future<void> setAutoConnect(String id, bool enabled) async {
    final timer = preferences.timers[id];
    if (timer == null) return;
    timer.autoConnect = enabled;
    if (enabled) _paused.remove(id);
    if (mounted) notifyListeners();
    await _savePreferences();
    if (enabled) await _autoScan();
  }

  Future<void> _autoScan() async {
    if (!mounted || scanning || busy || connectedCount >= 5) return;
    if (!preferences.timers.values.any(
      (t) =>
          t.autoConnect &&
          !_paused.contains(t.id) &&
          !(links[t.id]?.device.isConnected ?? false),
    )) {
      return;
    }
    await scan(requestPermissions: false);
  }

  Future<void> _connectKnown() async {
    if (_autoConnecting || busy || !mounted) return;
    _autoConnecting = true;
    final nearby = found.map((r) => r.device.remoteId.str).toSet();
    try {
      for (final timer in preferences.ordered) {
        if (!mounted || connectedCount >= 5) break;
        if (!timer.autoConnect ||
            _paused.contains(timer.id) ||
            !nearby.contains(timer.id)) {
          continue;
        }
        final device =
            links[timer.id]?.device ?? BluetoothDevice.fromId(timer.id);
        if (!device.isConnected) await connect(device, automatic: true);
      }
    } finally {
      _autoConnecting = false;
    }
  }

  void _listenForScan() {
    if (_scanSubscription != null) return;
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        _change(() => found = results);
        unawaited(_connectKnown());
      }
    }, onError: (Object e) => _report('Результаты поиска', e));
    _scanningSubscription = FlutterBluePlus.isScanning.listen((value) {
      if (mounted) _change(() => scanning = value);
    });
  }

  void _show(String text) {
    if (mounted) _change(() => message = text);
  }

  void _report(String operation, Object error) {
    final detail = '$operation: $error';
    debugPrint('PACE timer $detail');
    _record({
      'error': detail.substring(0, detail.length > 3000 ? 3000 : detail.length),
    });
    if (mounted) {
      _change(() {
        lastError = detail;
        message = timerErrorMessage(error);
      });
    }
    unawaited(
      getApplicationDocumentsDirectory()
          .then(
            (dir) => File('${dir.path}/timer-last-error.txt')
                .writeAsString('${DateTime.now().toIso8601String()} $detail'),
          )
          .catchError((Object _) => File('')),
    );
  }

  Future<void> scan({bool requestPermissions = true}) async {
    if (scanning || busy) return;
    _listenForScan();
    try {
      final sdk =
          await const MethodChannel('pace/audio')
              .invokeMethod<int>('androidSdk') ??
          31;
      final required = sdk >= 31
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.locationWhenInUse];
      final permissions = requestPermissions
          ? await required.request()
          : {
              for (final permission in required)
                permission: await permission.status,
            };
      if (permissions.values.any((status) => !status.isGranted)) {
        if (!requestPermissions) return;
        _show(
          sdk >= 31
              ? 'Разрешите «Устройства поблизости» для IPSC тренировОчка в настройках телефона.'
              : 'Разрешите геолокацию для поиска Bluetooth на этой версии Android.',
        );
        return;
      }
      if (await FlutterBluePlus.adapterState
              .where((state) => state != BluetoothAdapterState.unknown)
              .first
              .timeout(const Duration(seconds: 5)) !=
          BluetoothAdapterState.on) {
        if (requestPermissions) {
          _show('Включите Bluetooth на телефоне, затем повторите поиск.');
        }
        return;
      }
      if (!mounted) return;
      _change(() {
        searched = true;
        found = [];
        lastError = null;
        message = requestPermissions
            ? 'Ищем таймер. Выберите своё устройство.'
            : 'Ищем сохранённые таймеры…';
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      _report('Поиск таймеров', e);
    }
  }

  Future<void> connect(BluetoothDevice device, {bool automatic = false}) async {
    if (busy || connectedCount >= 5 || device.isConnected) {
      return;
    }
    _change(() => busy = true);
    final link = links[device.remoteId.str] ?? TimerLink(device);
    if (!automatic || selectedId == null) {
      selectedId = device.remoteId.str;
      preferences.selectedId = selectedId;
    }
    _paused.remove(device.remoteId.str);
    links[device.remoteId.str] = link;
    try {
      await FlutterBluePlus.stopScan();
      await device.connect(mtu: null, timeout: const Duration(seconds: 15));
      if (!mounted) {
        await device.disconnect();
        return;
      }
      await _syncService();
      await link.connection?.cancel();
      link.connection = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          link.notifications?.cancel();
          link.notifications = null;
          link.decoder = TimerProtocols.decoder(link.profile);
          finishSeries(link, partial: true);
          unawaited(_syncService());
          link.status =
              preferences.timers[device.remoteId.str]?.autoConnect == true &&
                  !_paused.contains(device.remoteId.str)
              ? 'Восстанавливаем связь… Серия может быть неполной.'
              : 'Отключён; сохранённые времена могут быть неполными';
          if (mounted) _change(() {});
        }
      });
      link.services = await device.discoverServices();
      if (!mounted) {
        await device.disconnect();
        return;
      }
      final id = device.remoteId.str;
      final saved = preferences.timers.putIfAbsent(
        id,
        () => SavedTimer(
          id,
          device.platformName.isEmpty ? 'Таймер' : device.platformName,
        ),
      );
      if (device.platformName.isNotEmpty) saved.name = device.platformName;
      await _savePreferences();
      final c = legacyCharacteristic(link);
      if (c != null) {
        link.profile = TimerProtocols.autoId;
        await subscribe(link, c);
      } else {
        link.profile = TimerProtocols.rawId;
        link.status =
            'Протокол не распознан. Откройте технические подробности.';
      }
      _record({
        'device': device.remoteId.str,
        'name': device.platformName,
        'services': link.services
            .map(
              (s) => {
                'uuid': s.uuid.str,
                'characteristics': s.characteristics
                    .map(
                      (c) => {
                        'uuid': c.uuid.str,
                        'notify': c.properties.notify,
                        'indicate': c.properties.indicate,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      });
    } catch (e) {
      await device.disconnect();
      await link.connection?.cancel();
      link.status = 'Ошибка подключения: $e';
      _report('Подключение', e);
    } finally {
      if (mounted) _change(() => busy = false);
    }
  }

  bool _record(Map<String, dynamic> record) {
    if (full) return false;
    record['at'] = DateTime.now().toUtc().toIso8601String();
    final size = utf8.encode(jsonEncode(record)).length;
    if (diagnosticBytes + size > 10 * 1024 * 1024 || _records.length >= 50000) {
      full = true;
      _show(
        'Диагностика заполнена; новые сырые пакеты не сохраняются. Приём времён продолжается.',
      );
      return false;
    }
    diagnosticBytes += size;
    _records.add(record);
    return true;
  }

  Future<void> subscribe(
    TimerLink link,
    BluetoothCharacteristic characteristic,
  ) async {
    try {
      await link.notifications?.cancel();
      link.decoder = TimerProtocols.decoder(link.profile);
      finishSeries(link, partial: true);
      link.notifications = characteristic.onValueReceived.listen((bytes) {
        receive(
          link,
          bytes,
          service: characteristic.serviceUuid.str,
          characteristic: characteristic.uuid.str,
        );
      }, onError: (Object e) => _report('Приём выстрелов', e));
      await characteristic.setNotifyValue(true);
      if (!mounted) {
        await link.notifications?.cancel();
        return;
      }
      link.status = link.profile == TimerProtocols.rawId
          ? 'Диагностика включена. Времена выстрелов пока не распознаются.'
          : link.profile == TimerProtocols.autoId
          ? 'Определяем протокол. Запустите серию на таймере; времена сверяйте с его экраном.'
          : 'Приём включён. Запустите новую серию на таймере, затем остановите её.';
      if (mounted) _change(() {});
    } catch (e) {
      await link.notifications?.cancel();
      link.notifications = null;
      _report('Начало приёма', e);
    }
  }

  void receive(
    TimerLink link,
    List<int> bytes, {
    String? service,
    String? characteristic,
  }) {
    _record({
      'device': link.device.remoteId.str,
      'service': service,
      'characteristic': characteristic,
      'profile': link.profile,
      'hex': bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' '),
    });
    final events = link.decoder.add(bytes);
    if (link.profile == TimerProtocols.autoId && events.isNotEmpty) {
      link.profile = events.first.profileId;
      link.acceptedLegacy = true;
      link.status = 'Special Pie legacy: протокол распознан, приём включён.';
      final saved = preferences.timers[link.device.remoteId.str];
      if (saved != null) {
        saved.profile = link.profile;
        unawaited(_savePreferences());
      }
    }
    for (final event in events) {
      if (event.kind == TimerEventKind.start) {
        finishSeries(link);
        link.pending.removeWhere((series) => series.saved);
        if (link.pending.length >= 100) {
          _show(
            'Лимит 100 серий на таймер: экспортируйте JSON. Новая серия не записана.',
          );
          link.active = null;
          continue;
        }
        final pending = TimerPendingSeries(
          '$_sessionId-${link.device.remoteId.str}-${_nextSeriesId++}',
          '${link.profile} / ${link.device.remoteId.str} / unqualified',
        );
        link.pending.add(pending);
        link.active = pending;
      }
      if (event.kind == TimerEventKind.shot && link.active != null) {
        if (link.active!.times.length < 10000) {
          link.active!.times.add(event.seconds!);
        } else {
          _show(
            'Лимит 10000 выстрелов: серия неполная; приём этой серии остановлен.',
          );
          finishSeries(link, partial: true);
        }
      }
      if (event.kind == TimerEventKind.stop) {
        finishSeries(link);
      }
    }
    if (mounted) _change(() {});
  }

  Future<void> disconnect(TimerLink link) async {
    _paused.add(link.device.remoteId.str);
    try {
      await link.notifications?.cancel();
      await link.connection?.cancel();
      await link.device.disconnect();
      link.notifications = null;
      finishSeries(link, partial: true);
      await _syncService();
      link.status = 'Отключён. Серии сохранены на этом экране.';
      if (mounted) _change(() {});
    } catch (e) {
      _show('Отключение: $e');
    }
  }

  Future<void> exportDiagnostics() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/timer-diagnostics-${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(
        jsonEncode({
          'schema': 1,
          'qualified': false,
          'truncated': full,
          'records': _records,
          'series': [
            for (final link in links.values)
              for (final series in link.pending)
                {
                  'id': series.id,
                  'source': series.source,
                  'complete': series.complete,
                  'saved': series.saved,
                  'times': series.times,
                },
          ],
        }),
      );
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'Диагностика таймеров: содержит идентификаторы Bluetooth устройств.',
        ),
      );
    } catch (e) {
      _show('Экспорт: $e');
    }
  }

  TimerLink? get selected => links[selectedId];
  void select(String id) {
    _change(() => selectedId = id);
    preferences.selectedId = id;
    unawaited(_savePreferences());
  }

  void showMessage(String text) => _show(text);
  BluetoothCharacteristic? legacyCharacteristic(TimerLink link) => link.services
      .expand((s) => s.characteristics)
      .where(
        (c) =>
            c.serviceUuid == Guid('fff0') &&
            c.uuid == Guid('fff1') &&
            (c.properties.notify || c.properties.indicate),
      )
      .firstOrNull;

  void finishSeries(TimerLink link, {bool partial = false}) {
    final series = link.active;
    link.active = null;
    if (series == null) return;
    series.complete = true;
    series.partial = partial;
    if (series.times.isNotEmpty) unawaited(saveSeries(series));
    if (mounted) notifyListeners();
  }

  Future<void> saveSeries(TimerPendingSeries series) async {
    if (series.saved || series.saving || series.times.isEmpty) return;
    series.saving = true;
    if (mounted) notifyListeners();
    try {
      series.saved = await onImport(
        List.of(series.times),
        '${series.source} / ${series.id}${series.partial ? " / partial" : ""}',
      );
      if (!series.saved) _show('Серия не сохранена. Повторите сохранение.');
    } catch (e) {
      _report('Сохранение серии', e);
    } finally {
      series.saving = false;
      if (mounted) notifyListeners();
    }
  }

  Future<void> _serviceQueue = Future.value();
  Future<void> refreshBackgroundService() => _syncService();
  Future<void> _syncService() {
    _serviceQueue = _serviceQueue.then((_) async {
      final needed = (connectedCount > 0 || watchBridgeRunning) && !_disposed;
      if (needed == serviceRunning) return;
      try {
        if (needed) {
          final sdk =
              await const MethodChannel('pace/audio')
                  .invokeMethod<int>('androidSdk') ??
              31;
          if (sdk >= 33 &&
              !(await Permission.notification.request()).isGranted) {
            throw StateError(
              'Разрешите уведомления IPSC тренировОчка для фонового приёма.',
            );
          }
        }
        await const MethodChannel(
          'pace/audio',
        ).invokeMethod<void>(needed ? 'timerServiceStart' : 'timerServiceStop');
        serviceRunning = needed;
        backgroundStatus = needed
            ? 'Фоновый сервис включён. При закрытии приложения системой соединения могут прерваться.'
            : 'Фоновый сервис остановлен.';
      } catch (e) {
        serviceRunning = false;
        backgroundStatus = 'Фоновый сервис недоступен. Работайте с открытым приложением и включённым экраном.';
        _report('Фоновый приём', e);
      }
      if (mounted) notifyListeners();
    });
    return _serviceQueue;
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _scanSubscription?.cancel();
    _scanningSubscription?.cancel();
    unawaited(FlutterBluePlus.stopScan().catchError((Object _) {}));
    for (final link in links.values) {
      finishSeries(link, partial: true);
      link.notifications?.cancel();
      link.connection?.cancel();
      unawaited(link.device.disconnect().catchError((Object _) {}));
    }
    unawaited(_syncService());
    super.dispose();
  }
}
