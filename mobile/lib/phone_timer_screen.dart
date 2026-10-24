import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'live_shot_detector.dart';
import 'watch_bridge.dart';

class PhoneTimerScreen extends StatefulWidget {
  const PhoneTimerScreen({super.key, required this.onSave, this.watchBridge});
  final WatchBridge? watchBridge;
  final Future<bool> Function(List<double> times, String source) onSave;

  @override
  State<PhoneTimerScreen> createState() => _PhoneTimerScreenState();
}

class _PhoneTimerScreenState extends State<PhoneTimerScreen>
    with WidgetsBindingObserver {
  static const _audio = MethodChannel('pace/audio');
  static const _microphone = EventChannel('pace/microphone');
  final _detector = LiveShotDetector();
  final _delay = TextEditingController(text: '3');
  final _par = TextEditingController(text: '0');
  final _clock = Stopwatch();
  final _shots = <double>[];
  StreamSubscription<dynamic>? _subscription;
  Timer? _ticker;
  Timer? _limit;
  Future<void> _settingsWrite = Future<void>.value();
  double _sensitivity = 50, _interval = 100, _duration = 600, _gain = 100;
  double _level = 0;
  bool _echoSuppression = true;
  double _echoWindow = 180;
  bool _active = false, _testing = false, _running = false;
  bool _saved = false, _saving = false, _allowPop = false, _previewing = false;
  bool _clipped = false, _loaded = false;
  int _token = 0;
  bool _watchStarted = false, _watchFailed = false;
  bool _foreground = true;
  String _status = 'Готов';
  String _volume = 'Громкость медиа: неизвестна';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.watchBridge?.attachPhone(_watchCommand);
    unawaited(_load());
    unawaited(_readVolume());
  }

  Future<File> _settingsFile() async => File(
    '${(await getApplicationDocumentsDirectory()).path}/phone-timer-settings.json',
  );

  Future<void> _load() async {
    try {
      final file = await _settingsFile();
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map && mounted) {
          double value(String key, double fallback, double min, double max) {
            final n = raw[key];
            return n is num && n.isFinite && n >= min && n <= max
                ? n.toDouble()
                : fallback;
          }

          _sensitivity = value('sensitivity', 50, 0, 100);
          _interval = value('interval', 100, 60, 300);
          _echoSuppression = raw['echoSuppression'] is bool
              ? raw['echoSuppression'] as bool
              : true;
          _echoWindow = value('echoWindow', 180, 80, 400);
          _duration = value('duration', 600, 150, 1500);
          _gain = value('gain', 100, 10, 100);
          _delay.text = value('delay', 3, 0, 60).toString();
          _par.text = value('par', 0, 0, 600).toString();
          _configure();
        }
      }
    } catch (_) {
      // Invalid or unavailable settings fall back to safe defaults.
    }
    if (mounted) {
      setState(() => _loaded = true);
      _publishWatch();
    }
  }

  void _publishWatch({bool newRun = false}) {
    widget.watchBridge?.phoneState(
      !_foreground || _watchFailed
          ? WatchPhase.unavailable
          : _active
          ? (_running ? WatchPhase.running : WatchPhase.preparing)
          : _watchStarted
          ? WatchPhase.finished
          : WatchPhase.idle,
      _watchStarted ? _shots : [],
      canControl:
          _foreground &&
          _loaded &&
          !_testing &&
          !_saving &&
          !_previewing &&
          (_active || _shots.isEmpty || _saved),
      newRun: newRun,
      failed: _watchFailed,
    );
  }

  Future<void> _watchCommand(bool start) async {
    if (!mounted ||
        !_foreground ||
        !_loaded ||
        _saving ||
        _testing ||
        _previewing) {
      throw StateError('Откройте готовый телефонный таймер');
    }
    if (start) {
      if (_active || (_shots.isNotEmpty && !_saved)) {
        throw StateError('Сначала сохраните предыдущую серию на телефоне');
      }
      unawaited(_start());
    } else {
      if (!_active) throw StateError('Таймер уже остановлен');
      final hadShots = _running;
      await _stop('Завершено с часов');
      if (hadShots) await _save();
    }
  }

  Future<void> _persist() async {
    final d = double.tryParse(_delay.text.replaceAll(',', '.'));
    final p = double.tryParse(_par.text.replaceAll(',', '.'));
    if (d == null ||
        p == null ||
        !d.isFinite ||
        !p.isFinite ||
        d < 0 ||
        d > 60 ||
        p < 0 ||
        p > 600) {
      return;
    }
    final data = jsonEncode({
      'sensitivity': _sensitivity,
      'interval': _interval,
      'echoSuppression': _echoSuppression,
      'echoWindow': _echoWindow,
      'duration': _duration,
      'gain': _gain,
      'delay': d,
      'par': p,
    });
    try {
      final previous = _settingsWrite;
      final write = previous.catchError((Object _) {}).then((_) async {
        await (await _settingsFile()).writeAsString(data, flush: true);
      });
      _settingsWrite = write;
      await write;
    } catch (_) {
      if (mounted) {
        setState(() => _status = 'Настройки не сохранены на телефоне');
      }
    }
  }

  void _configure() => _detector.configure(
    sensitivity: _sensitivity,
    minInterval: _interval / 1000,
    echoSuppression: _echoSuppression,
    echoWindow: _echoWindow / 1000,
  );

  void _setVolume(Map<dynamic, dynamic> data) {
    if (mounted) {
      setState(() {
        _volume =
            'Громкость медиа: ${data['mediaVolume'] ?? '?'} / ${data['mediaMax'] ?? '?'}';
      });
    }
  }

  Future<void> _readVolume() async {
    try {
      final raw = await _audio.invokeMapMethod<dynamic, dynamic>('audioStatus');
      if (raw != null) _setVolume(raw);
    } catch (_) {
      /* The explicit preview reports audio failures. */
    }
  }

  Future<Map<dynamic, dynamic>> _beep() async {
    final raw = await _audio.invokeMapMethod<dynamic, dynamic>('beep', {
      'durationMs': _duration.round(),
      'gain': _gain / 100,
    });
    if (raw == null) throw StateError('Нет отметки начала сигнала');
    _setVolume(raw);
    return raw;
  }

  Future<void> _preview() async {
    if (_active || _previewing) return;
    final token = ++_token;
    setState(() => _previewing = true);
    try {
      await _beep();
      await Future<void>.delayed(Duration(milliseconds: _duration.round()));
    } catch (e) {
      if (mounted && token == _token) {
        setState(() => _status = 'Сигнал недоступен: $e');
      }
    } finally {
      if (mounted && token == _token) setState(() => _previewing = false);
    }
  }

  Future<bool> _discard() async {
    if (_shots.isEmpty || _saved) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Серия не сохранена'),
            content: const Text('Удалить результаты этой серии?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Оставить'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Удалить'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _start({bool test = false}) async {
    if (_active || _previewing || _saving || !_loaded) return;
    final d = double.tryParse(_delay.text.replaceAll(',', '.'));
    final p = double.tryParse(_par.text.replaceAll(',', '.'));
    if (!test &&
        (d == null ||
            p == null ||
            !d.isFinite ||
            !p.isFinite ||
            d < 0 ||
            d > 60 ||
            p < 0 ||
            p > 600)) {
      setState(() => _status = 'Задержка 0–60 с; PAR 0–600 с (0 — вручную)');
      _watchFailed = true;
      _publishWatch();
      return;
    }
    if (!test && _shots.isNotEmpty && !_saved && !await _discard()) return;
    if (!mounted || _active) return;
    final token = ++_token;
    setState(() {
      _active = true;
      _testing = test;
      _clipped = false;
      _status = 'Подготовка микрофона…';
    });
    _watchStarted = false;
    _watchFailed = false;
    _publishWatch(newRun: true);
    try {
      final permission = await Permission.microphone.request();
      if (!mounted || token != _token) return;
      if (!permission.isGranted) {
        throw StateError(
          'Разрешите микрофон для IPSC тренировОчка в настройках телефона',
        );
      }
      _subscription = _microphone.receiveBroadcastStream().listen(
        (dynamic raw) {
          if (!mounted || token != _token || raw is! Map) return;
          if (raw['event'] == 'stopped') {
            unawaited(
              _stop('Микрофон остановлен: ${raw['reason'] ?? 'нет данных'}'),
            );
            return;
          }
          try {
            final frame = MicFrame.fromMap(raw);
            final shot = _running ? _detector.add(frame) : null;
            setState(() {
              _level = frame.peak.clamp(0.0, 1.0);
              _clipped = _clipped || frame.clipped;
              if (shot != null) _shots.add(shot);
            });
            if (shot != null) _publishWatch();
          } catch (_) {
            unawaited(_stop('Неверные данные микрофона. Повторите запуск.'));
          }
        },
        onError: (Object e) {
          if (mounted && token == _token) {
            unawaited(_stop('Ошибка микрофона: $e'));
          }
        },
      );
      await _audio.invokeMethod<dynamic>('micStart');
      if (!mounted || token != _token) return;
      if (test) {
        setState(
          () => _status = 'Проверка микрофона: хлопните и настройте порог',
        );
        return;
      }
      unawaited(_persist());
      setState(() => _status = 'Приготовиться');
      await Future<void>.delayed(Duration(milliseconds: (d! * 1000).round()));
      if (!mounted || token != _token) return;
      final result = await _beep();
      if (!mounted || token != _token) return;
      final at = result['at'];
      if (at is! num || !at.isFinite) throw StateError('Нет времени сигнала');
      _detector.start(at.toDouble());
      _clock
        ..reset()
        ..start();
      setState(() {
        _shots.clear();
        _saved = false;
        _running = true;
        _status = 'СТАРТ';
      });
      _watchStarted = true;
      _publishWatch();
      _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (mounted) setState(() {});
      });
      _limit = Timer(
        Duration(milliseconds: ((p! > 0 ? p : 600) * 1000).round()),
        () {
          unawaited(_finish(p > 0));
        },
      );
    } catch (e) {
      _watchFailed = true;
      if (mounted && token == _token) await _stop('Не удалось запустить: $e');
    }
  }

  Future<void> _finish(bool par) async {
    final token = _token + 1;
    await _stop(par ? 'PAR / СТОП' : 'Лимит 10 минут');
    if (par && mounted && token == _token) await _preview();
  }

  Future<void> _stop(String message) async {
    if (message.startsWith('Ошибка') ||
        message.startsWith('Неверные') ||
        message.startsWith('Микрофон остановлен'))
      _watchFailed = true;
    ++_token;
    _running = false;
    _detector.stop();
    _clock.stop();
    _ticker?.cancel();
    _limit?.cancel();
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    for (final method in ['micStop', 'stopBeep']) {
      try {
        await _audio.invokeMethod<dynamic>(method);
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _active = false;
        _testing = false;
        _previewing = false;
        _level = 0;
        _status = message;
      });
      _publishWatch();
    }
  }

  Future<void> _save() async {
    if (_active || _saving || _saved || _shots.isEmpty) return;
    setState(() => _saving = true);
    _publishWatch();
    try {
      final saved = await widget.onSave(
        List<double>.of(_shots),
        'Микрофон телефона',
      );
      if (mounted) {
        setState(() {
          _saved = saved;
          _status = saved
              ? 'Серия сохранена'
              : 'Серия не сохранена. Можно повторить.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Не удалось сохранить: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
      if (mounted) _publishWatch();
    }
  }

  Future<void> _leave() async {
    if (_saving) return;
    await _stop('Остановлено');
    if (!mounted || !await _discard() || !mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _foreground = false;
      unawaited(_stop('Остановлено при сворачивании'));
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _publishWatch();
      unawaited(_readVolume());
    }
  }

  @override
  void dispose() {
    widget.watchBridge?.detachPhone();
    WidgetsBinding.instance.removeObserver(this);
    ++_token;
    _ticker?.cancel();
    _limit?.cancel();
    _clock.stop();
    _detector.stop();
    unawaited(_subscription?.cancel());
    for (final method in ['micStop', 'stopBeep']) {
      unawaited(
        _audio.invokeMethod<dynamic>(method).catchError((Object _) => null),
      );
    }
    _delay.dispose();
    _par.dispose();
    super.dispose();
  }

  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    ValueChanged<double> change, {
    bool enabled = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title),
      Slider(
        value: value,
        min: min,
        max: max,
        onChanged: enabled && _loaded
            ? (v) => setState(() {
                change(v);
                _configure();
              })
            : null,
        onChangeEnd: (_) => unawaited(_persist()),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Таймер телефона')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Настройте чувствительность под телефон и дистанцию. Шум и эхо могут давать ложные отметки: сверяйте серию с внешним таймером.',
            ),
            const SizedBox(height: 12),
            Text(_status, style: Theme.of(context).textTheme.titleLarge),
            Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(2)} с',
                  style: const TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            Text(
              'Выстрелов: ${_shots.length}',
              style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            ),
            Text(
              'Первый: ${_shots.isEmpty ? '—' : '${_shots.first.toStringAsFixed(2)} с'}',
            ),
            Text(
              'Последний сплит: ${_shots.length < 2 ? '—' : '${(_shots.last - _shots[_shots.length - 2]).toStringAsFixed(2)} с'}',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: !_loaded || _saving || _previewing
                  ? null
                  : _active
                  ? () => unawaited(_stop('Остановлено'))
                  : () => unawaited(_start()),
              child: Text(_active ? 'Остановить' : 'Начать'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: !_active && !_saving && !_saved && _shots.isNotEmpty
                  ? _save
                  : null,
              child: Text(
                _saving
                    ? 'Сохранение…'
                    : _saved
                    ? 'Сохранено'
                    : 'Сохранить серию',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Уровень микрофона: ${(_level * 100).round()}% · порог ${(_detector.threshold * 100).toStringAsFixed(1)}%',
            ),
            Stack(
              children: [
                LinearProgressIndicator(value: _level, minHeight: 14),
                LayoutBuilder(
                  builder: (context, constraints) => Padding(
                    padding: EdgeInsets.only(
                      left:
                          (constraints.maxWidth - 2) *
                          _detector.threshold.clamp(0.0, 1.0),
                    ),
                    child: Container(
                      width: 2,
                      height: 14,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
            if (_clipped)
              const Text(
                'Микрофон перегружен. Увеличьте расстояние до источника звука; отметки могут быть неточными.',
              ),
            ExpansionTile(
              title: const Text('Настройки таймера'),
              subtitle: const Text('Чувствительность, эхо и сигнал'),
              children: [
                _slider(
                  'Чувствительность: ${_sensitivity.round()} (выше — чувствительнее)',
                  _sensitivity,
                  0,
                  100,
                  (v) => _sensitivity = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Фильтр эха'),
                  value: _echoSuppression,
                  onChanged: !_loaded
                      ? null
                      : (value) {
                          setState(() {
                            _echoSuppression = value;
                            _configure();
                          });
                          unawaited(_persist());
                        },
                ),
                const Text(
                  'Подавляет более слабые повторные импульсы. Если пропускает быстрые выстрелы — уменьшите окно или отключите.',
                ),
                _slider(
                  'Окно эха: ${_echoWindow.round()} мс',
                  _echoWindow,
                  80,
                  400,
                  (value) => _echoWindow = value,
                  enabled: _echoSuppression,
                ),
                _slider(
                  'Минимальный интервал: ${_interval.round()} мс',
                  _interval,
                  60,
                  300,
                  (v) => _interval = v,
                ),
                OutlinedButton(
                  onPressed: _active || _previewing || _saving || !_loaded
                      ? null
                      : () => unawaited(_start(test: true)),
                  child: const Text('Проверить микрофон'),
                ),
                if (_testing)
                  const Text(
                    'Проверка не записывает выстрелы. Нажмите «Остановить», чтобы закончить.',
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _delay,
                  enabled: !_active && _loaded && !_previewing,
                  decoration: const InputDecoration(
                    labelText: 'Задержка, с (0–60)',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onSubmitted: (_) => unawaited(_persist()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _par,
                  enabled: !_active && _loaded && !_previewing,
                  decoration: const InputDecoration(
                    labelText: 'PAR, с (0 — остановить вручную, до 600)',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onSubmitted: (_) => unawaited(_persist()),
                ),
                const SizedBox(height: 16),
                Text(_volume),
                const Text(
                  'Если тихо, увеличьте громкость «Медиа» кнопками телефона. Приложение не меняет системную громкость.',
                ),
                _slider(
                  'Длительность сигнала: ${_duration.round()} мс',
                  _duration,
                  150,
                  1500,
                  (v) => _duration = v,
                  enabled: !_active && !_previewing,
                ),
                _slider(
                  'Уровень сигнала приложения: ${_gain.round()}%',
                  _gain,
                  10,
                  100,
                  (v) => _gain = v,
                  enabled: !_active && !_previewing,
                ),
                OutlinedButton(
                  onPressed: _active || _previewing || !_loaded
                      ? null
                      : _preview,
                  child: const Text('Проверить сигнал'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _shots.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'Выстрел ${i + 1}: ${_shots[i].toStringAsFixed(2)} с',
                ),
                subtitle: Text(
                  'Сплит: ${(_shots[i] - (i == 0 ? 0 : _shots[i - 1])).toStringAsFixed(2)} с',
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
