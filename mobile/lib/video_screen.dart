import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

import 'video_timeline.dart';
import 'video_playback_clock.dart';

import 'domain.dart';
import 'video_analysis.dart';

List<Map<String, dynamic>> decodeVideoLinks(String source) {
  final data = jsonDecode(source);
  if (data is! List) throw const FormatException('Ожидается список видео');
  final paths = <String>{};
  final entries = data.map((value) {
    if (value is! Map) throw const FormatException('Повреждена запись видео');
    final entry = Map<String, dynamic>.from(value);
    if (entry['path'] is! String ||
        (entry['path'] as String).isEmpty ||
        entry['name'] is! String ||
        !paths.add(entry['path'] as String)) {
      throw const FormatException('Повреждён путь или имя видео');
    }
    for (final key in ['start', 'comparisonOffset', 'comparisonCorrection']) {
      if (entry[key] != null &&
          (entry[key] is! num || !(entry[key] as num).isFinite)) {
        throw FormatException('Повреждено поле $key');
      }
    }
    if (entry['syncStatus'] != null &&
        ![
          'unprocessed',
          'manual',
          'detected',
          'missing',
        ].contains(entry['syncStatus'])) {
      throw const FormatException('Повреждено состояние синхронизации');
    }
    if (entry['beepCandidates'] != null) {
      final values = entry['beepCandidates'];
      if (values is! List ||
          values.any(
            (v) =>
                v is! Map ||
                v['time'] is! num ||
                !(v['time'] as num).isFinite ||
                (v['time'] as num) < -600 ||
                v['atBoundary'] is! bool,
          )) {
        throw const FormatException('Повреждены кандидаты стартового сигнала');
      }
    }
    for (final key in ['markers', 'candidates']) {
      if (entry[key] != null &&
          (entry[key] is! List ||
              (entry[key] as List).any((v) => v is! num || !v.isFinite))) {
        throw FormatException('Повреждено поле $key');
      }
    }
    if (entry['opacity'] != null &&
        (entry['opacity'] is! num ||
            !(entry['opacity'] as num).isFinite ||
            (entry['opacity'] as num) < 0 ||
            (entry['opacity'] as num) > 1)) {
      throw const FormatException('Повреждена прозрачность видео');
    }
    if (entry['runId'] != null && entry['runId'] is! String ||
        entry['comparisonPath'] != null && entry['comparisonPath'] is! String) {
      throw const FormatException('Повреждена привязка видео');
    }
    return entry;
  }).toList();
  // Migrate the old absolute offset once, before any video's start is edited.
  for (final entry in entries) {
    if (entry['comparisonPath'] == null ||
        entry.containsKey('comparisonCorrection')) {
      continue;
    }
    final linked = entries.where((v) => v['path'] == entry['comparisonPath']);
    final otherStart = linked.isEmpty
        ? 0.0
        : (linked.first['start'] as num? ?? 0).toDouble();
    entry['comparisonCorrection'] =
        (entry['comparisonOffset'] as num? ?? 0).toDouble() -
        (otherStart - (entry['start'] as num? ?? 0).toDouble());
  }
  return entries;
}

class VideoScreen extends StatefulWidget {
  const VideoScreen({super.key, required this.runs, required this.shooters});
  final List<Run> runs;
  final List<Shooter> shooters;
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  final _videos = <Map<String, dynamic>>[];
  VideoPlayerController? _player;
  VideoPlayerController? _comparison;
  Map<String, dynamic>? _selected;
  String? _runId;
  double _start = 0;
  double _comparisonOffset = 0;
  double _speed = 1;
  bool _mutedA = false;
  bool _mutedB = true;
  bool _fullscreenOpen = false;
  bool _busy = false;
  bool _opening = false;
  bool? _calibrating;
  bool _analyzing = false;
  bool _seeking = false;
  int _seekEpoch = 0;
  double _lastCorrection = -10;
  final _monotonic = Stopwatch()..start();
  final _primaryClock = PlaybackClock();
  final _comparisonClock = PlaybackClock();

  double get _now => _monotonic.elapsedMicroseconds / 1e6;
  bool _hasStart(Map<String, dynamic>? entry) =>
      entry != null &&
      (entry['syncStatus'] == 'manual' ||
          entry['syncStatus'] == 'detected' ||
          entry['syncStatus'] == null && (entry['start'] as num? ?? 0) > 0);
  bool get _readyToCompare =>
      _hasStart(_selected) &&
      (_comparison == null || _hasStart(_comparisonEntry)) &&
      _playStartPosition + .01 < _endPosition;

  bool _exporting = false;
  double _frameStep = .04;
  double _opacity = .5;
  final _revision = ValueNotifier<int>(0);

  void _changed(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _revision.value++;
  }

  bool _overlay = false;
  bool _syncingComparison = false;
  Future<void> _saving = Future.value();
  String _notice =
      'Выберите видео и сохранённую серию или режим «Без таймера».';
  List<double> _markers = [];
  List<double> _candidates = [];
  File? _metadata;
  bool _metadataReady = false;
  bool _loadFailed = false;
  int _openGeneration = 0;
  int _comparisonGeneration = 0;
  String? _comparisonPath;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_runId != null && !widget.runs.any((run) => run.id == _runId)) {
      _runId = null;
      _persist();
    }
  }

  Future<void> _load() async {
    if (mounted) {
      _changed(() {
        _metadataReady = false;
        _loadFailed = false;
      });
    }
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/video-links.json');
      final exists = await file.exists();
      final data = exists
          ? decodeVideoLinks(await file.readAsString())
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      _changed(() {
        _metadata = file;
        _videos
          ..clear()
          ..addAll(data);
        _metadataReady = true;
      });
    } catch (error) {
      if (!mounted) return;
      _changed(() {
        _loadFailed = true;
        _notice =
            'Не удалось прочитать список видео: $error. Исходный файл сохранён. Повторите чтение после исправления файла.';
      });
    }
  }

  void _message(String value) {
    if (mounted) _changed(() => _notice = value);
  }

  Future<void> _save() async {
    if (!_metadataReady) {
      throw StateError('Сохранение заблокировано: список видео не прочитан');
    }
    if (_selected != null) {
      _selected!.addAll({
        'runId': _runId,
        'start': _start,
        'markers': _markers,
        'candidates': _candidates,
        'comparisonPath': _comparisonPath,
        'comparisonOffset': _comparisonOffset,
        'comparisonCorrection': _comparisonOffset - (_comparisonStart - _start),
        'overlay': _overlay,
        'opacity': _opacity,
      });
    }
    for (final entry in _videos) {
      final linked = _videos.where((v) => v['path'] == entry['comparisonPath']);
      if (linked.isEmpty) continue;
      entry['comparisonOffset'] =
          (linked.first['start'] as num? ?? 0).toDouble() -
          (entry['start'] as num? ?? 0).toDouble() +
          (entry['comparisonCorrection'] as num? ?? 0).toDouble();
    }
    final file = _metadata;
    if (file == null) return;
    final snapshot = jsonEncode(_videos);
    _saving = _saving.catchError((Object _) {}).then((_) async {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(file.path);
    });
    await _saving;
  }

  Future<void> _persist() async {
    try {
      await _save();
    } catch (error) {
      _message('Не удалось сохранить: $error');
    }
  }

  Future<void> _import(ImageSource source, {bool compare = false}) async {
    if (_busy || !_metadataReady) return;
    _changed(() => _busy = true);
    try {
      final picked = await ImagePicker().pickVideo(source: source);
      if (picked == null || !mounted) return;
      final directory = await getApplicationDocumentsDirectory();
      final extension = picked.path
          .split('.')
          .last
          .replaceAll(RegExp('[^a-zA-Z0-9]'), '');
      final path =
          '${directory.path}/video-${DateTime.now().microsecondsSinceEpoch}.${extension.isEmpty ? 'mp4' : extension}';
      if (!mounted) return;
      await File(picked.path).copy(path);
      if (!mounted) return;
      final entry = <String, dynamic>{
        'path': path,
        'name': picked.name,
        'start': 0.0,
        'syncStatus': 'unprocessed',
        'markers': <double>[],
        'candidates': <double>[],
      };
      _videos.add(entry);
      await _save();
      if (!mounted) return;
      if (compare) {
        await _openComparison(path);
      } else {
        await _open(entry);
      }
    } catch (error) {
      _message('Не удалось открыть видео: $error');
    } finally {
      if (mounted) _changed(() => _busy = false);
    }
  }

  Future<String> _previewPath(String path) async {
    final preview = await const MethodChannel(
      'pace/audio',
    ).invokeMapMethod<String, dynamic>('prepareVideoPreview', {'path': path});
    final result = preview?['path'];
    if (result is! String || result.isEmpty) {
      throw StateError('Не создана копия для просмотра');
    }
    return result;
  }

  Future<void> _open(Map<String, dynamic> entry) async {
    if (_opening || _analyzing || _exporting) return;
    _changed(() {
      _opening = true;
      _calibrating = null;
    });
    final generation = ++_openGeneration;
    ++_comparisonGeneration;
    bool active() => mounted && generation == _openGeneration;
    VideoPlayerController? controller;
    var installed = false;
    try {
      // Release both decoders before preparing/opening another HEVC source.
      final oldPrimary = _player;
      final oldSecondary = _comparison;
      oldPrimary?.removeListener(_tick);
      oldSecondary?.removeListener(_comparisonTick);
      _changed(() {
        _player = null;
        _comparison = null;
      });
      await Future.wait([
        if (oldPrimary != null) oldPrimary.dispose(),
        if (oldSecondary != null) oldSecondary.dispose(),
      ]);
      final path = await _previewPath(entry['path'] as String);
      if (!active()) return;
      controller = VideoPlayerController.file(
        File(path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize();
      if (!active()) return;
      await controller.setPlaybackSpeed(_speed);
      await controller.setVolume(_mutedA ? 0 : 1);
      if (!active()) return;
      _changed(() {
        _selected = entry;
        _player = controller;
        _runId = widget.runs.any((r) => r.id == entry['runId'])
            ? entry['runId'] as String?
            : null;
        _start = (entry['start'] as num? ?? 0).toDouble();
        _markers = (entry['markers'] as List? ?? [])
            .map((e) => (e as num).toDouble())
            .toList();
        _candidates = (entry['candidates'] as List? ?? [])
            .map((e) => (e as num).toDouble())
            .toList();
        _comparisonPath = entry['comparisonPath'] as String?;
        _comparisonOffset =
            _comparisonStart -
            _start +
            (entry['comparisonCorrection'] as num? ?? 0).toDouble();
        _overlay = entry['overlay'] == true;
        _opacity = (entry['opacity'] as num? ?? .5).toDouble().clamp(0, 1);
        _frameStep = .04;
        _notice =
            'Видео сохранено на устройстве. Укажите старт сигнала и серию.';
      });
      installed = true;
      _primaryClock.reset();
      controller.addListener(_tick);
      _observe(controller, _primaryClock);
      try {
        final info = await const MethodChannel('pace/audio')
            .invokeMapMethod<String, dynamic>('videoInfo', {'path': path});
        if (!active()) return;
        final rate = info?['frameRate'];
        if (rate is num && rate.isFinite && rate > 0 && rate <= 240) {
          _changed(() {
            _frameStep = 1 / rate;
          });
        }
      } on PlatformException {
        /* Frame rate is optional for imported codecs. */
      } on MissingPluginException {
        /* Older builds retain a labelled time step. */
      }

      if (!_hasStart(entry) && entry['syncStatus'] != 'missing') {
        await _analyze(automatic: true);
        if (!active()) return;
      }
      if (_comparisonPath != null) {
        await _openComparison(
          _comparisonPath!,
          restore: true,
          fromPrimary: true,
        );
        if (!active()) return;
      }
      if (_readyToCompare) await _seek(_playStartPosition);
    } catch (error) {
      if (active()) {
        _message(
          'Видео недоступно: ${error is PlatformException ? error.message ?? error.code : error}',
        );
      }
    } finally {
      if (!installed) await controller?.dispose();
      if (mounted) _changed(() => _opening = false);
    }
  }

  Future<void> _openComparison(
    String path, {
    bool restore = false,
    bool fromPrimary = false,
  }) async {
    if ((_opening && !fromPrimary) || _analyzing || _exporting) return;
    if (path == _selected?['path']) {
      _message('Выберите для B другой ролик.');
      return;
    }
    if (!fromPrimary) _changed(() => _opening = true);
    final generation = ++_comparisonGeneration;
    final primaryGeneration = _openGeneration;
    bool active() =>
        mounted &&
        generation == _comparisonGeneration &&
        primaryGeneration == _openGeneration;
    VideoPlayerController? controller;
    var installed = false;
    try {
      await _player?.pause();
      final previous = _comparison;
      previous?.removeListener(_comparisonTick);
      _changed(() => _comparison = null);
      await previous?.dispose();
      final preview = await _previewPath(path);
      if (!active()) return;
      controller = VideoPlayerController.file(
        File(preview),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await controller.initialize();
      if (!active()) return;
      await controller.setVolume(_mutedB ? 0 : 1);
      if (!active()) return;
      await controller.setPlaybackSpeed(_speed);
      if (!active()) return;
      _changed(() {
        _comparison = controller;
        _comparisonPath = path;
        _comparisonOffset =
            _comparisonStart -
            _start +
            (restore
                ? (_selected?['comparisonCorrection'] as num? ?? 0).toDouble()
                : 0);
      });
      installed = true;
      _comparisonClock.reset();
      controller.addListener(_comparisonTick);
      _observe(controller, _comparisonClock);
      if (!_hasStart(_comparisonEntry) &&
          _comparisonEntry?['syncStatus'] != 'missing') {
        await _analyze(compare: true, automatic: true);
        if (!active()) return;
      }
      await _seek(_readyToCompare ? _playStartPosition : _position);
      if (!active()) return;
      if (!restore) await _persist();
    } catch (error) {
      if (active()) {
        _message(
          'Второе видео недоступно: ${error is PlatformException ? error.message ?? error.code : error}',
        );
      }
    } finally {
      if (!installed) await controller?.dispose();
      if (!fromPrimary && mounted) _changed(() => _opening = false);
    }
  }

  double get _position => (_player?.value.position.inMilliseconds ?? 0) / 1000;
  void _observe(VideoPlayerController player, PlaybackClock clock) {
    final value = player.value;
    clock.observe(
      position: value.position.inMilliseconds / 1000,
      playing: value.isPlaying,
      buffering: value.isBuffering,
      speed: value.playbackSpeed,
      now: _now,
    );
  }

  void _tick() {
    final player = _player;
    if (player != null) _observe(player, _primaryClock);
    if (mounted) _changed(() {});
    if (!_seeking && _calibrating == null) {
      if (player != null &&
          player.value.isPlaying &&
          _position >= _endPosition - .01) {
        unawaited(
          Future.wait([
            player.pause(),
            if (_comparison != null) _comparison!.pause(),
          ]),
        );
      } else {
        unawaited(_syncComparison());
      }
    }
  }

  void _comparisonTick() {
    final comparison = _comparison;
    if (comparison != null) _observe(comparison, _comparisonClock);
    if (_calibrating == true && mounted) _changed(() {});
  }

  Future<void> _syncComparison() async {
    final comparison = _comparison;
    final player = _player;
    if (comparison == null ||
        player == null ||
        _syncingComparison ||
        _seeking ||
        _calibrating != null) {
      return;
    }
    _syncingComparison = true;
    try {
      if (!player.value.isPlaying || player.value.isBuffering) {
        if (comparison.value.isPlaying) await comparison.pause();
        return;
      }
      final now = _now;
      final relative = _primaryClock.projectedPosition(now) + _comparisonOffset;
      final duration = comparison.value.duration.inMilliseconds / 1000;
      final target = relative.clamp(0.0, duration);
      // Player samples arrive at different instants; compare their projections.
      final drift = (_comparisonClock.projectedPosition(now) - target).abs();
      if (drift > .15 && now - _lastCorrection > .75) {
        _lastCorrection = now;
        await comparison.seekTo(
          Duration(milliseconds: (target * 1000).round()),
        );
        _comparisonClock.reset();
        _observe(comparison, _comparisonClock);
      }
      if (!mounted ||
          player != _player ||
          comparison != _comparison ||
          _seeking ||
          _calibrating != null ||
          !player.value.isPlaying ||
          player.value.isBuffering) {
        return;
      }
      final play = relative >= 0 && relative < duration;
      if (play && !comparison.value.isPlaying) {
        await comparison.play();
        if (comparison == _comparison &&
            (_calibrating == false ||
                _calibrating == null && !player.value.isPlaying)) {
          await comparison.pause();
        }
      }
      if (!play && comparison.value.isPlaying) await comparison.pause();
    } catch (error) {
      _message('Ошибка синхронизации второго видео: $error');
    } finally {
      _syncingComparison = false;
    }
  }

  Future<void> _seek(double seconds) async {
    final generation = _openGeneration;
    final epoch = ++_seekEpoch;
    final player = _player;
    if (player == null) return;
    _seeking = true;
    try {
      final primaryTarget = seconds.clamp(
        0.0,
        player.value.duration.inMilliseconds / 1000,
      );
      final comparison = _comparison;
      final target = comparison == null
          ? 0.0
          : (primaryTarget + _comparisonOffset).clamp(
              0.0,
              comparison.value.duration.inMilliseconds / 1000,
            );
      await Future.wait([
        player.seekTo(Duration(milliseconds: (primaryTarget * 1000).round())),
        if (comparison != null)
          comparison.seekTo(Duration(milliseconds: (target * 1000).round())),
      ]);
      if (!mounted || generation != _openGeneration || epoch != _seekEpoch) {
        return;
      }
      _primaryClock.reset();
      _observe(player, _primaryClock);
      if (comparison != null) {
        _comparisonClock.reset();
        _observe(comparison, _comparisonClock);
      }
      _lastCorrection = _now;
    } finally {
      if (epoch == _seekEpoch) _seeking = false;
    }
  }

  double get _playStartPosition {
    final fromA = _start.clamp(0.0, double.infinity);
    return _comparison == null
        ? fromA
        : fromA.clamp(
            (-_comparisonOffset).clamp(0.0, double.infinity),
            double.infinity,
          );
  }

  double get _endPosition {
    final primary = (_player?.value.duration.inMilliseconds ?? 0) / 1000;
    final secondary = _comparison;
    return secondary == null
        ? primary
        : primary.clamp(
            0.0,
            (secondary.value.duration.inMilliseconds / 1000 - _comparisonOffset)
                .clamp(0.0, double.infinity),
          );
  }

  Future<void> _play() async {
    final player = _player;
    if (player == null || _opening || _analyzing) return;
    if (!_readyToCompare) {
      _message(
        'Для общего запуска укажите старт ${!_hasStart(_selected) ? 'A' : 'B'}. Откройте «Проверить старт» и найдите сигнал.',
      );
      return;
    }
    if (_calibrating == null && player.value.isPlaying) {
      await Future.wait([
        player.pause(),
        if (_comparison != null) _comparison!.pause(),
      ]);
    } else {
      _changed(() => _calibrating = null);
      await Future.wait([
        player.pause(),
        if (_comparison != null) _comparison!.pause(),
      ]);
      await player.setVolume(_mutedA ? 0 : 1);
      await _comparison?.setVolume(_mutedB ? 0 : 1);
      final position =
          _position < _playStartPosition || _position >= _endPosition - .05
          ? _playStartPosition
          : _position;
      await _seek(position);
      _seeking = true;
      try {
        await Future.wait([
          player.play(),
          if (_comparison != null) _comparison!.play(),
        ]);
      } finally {
        _seeking = false;
      }
    }
  }

  Future<void> _fromStart() async {
    await Future.wait([
      if (_player != null) _player!.pause(),
      if (_comparison != null) _comparison!.pause(),
    ]);
    _changed(() => _calibrating = null);
    if (!_readyToCompare) {
      _message('Сначала найдите старт в обоих роликах.');
      return;
    }
    await _seek(_playStartPosition);
  }

  Future<void> _calibrate(bool compare) async {
    final player = compare ? _comparison : _player;
    if (player == null || _opening || _analyzing) return;
    await Future.wait([
      if (_player != null) _player!.pause(),
      if (_comparison != null) _comparison!.pause(),
    ]);
    _changed(() => _calibrating = compare);
    await _player?.setVolume(compare ? 0 : 1);
    await _comparison?.setVolume(compare ? 1 : 0);
    await player.seekTo(Duration.zero);
    await player.play();
  }

  void _updateStart(bool compare, double value, String status) {
    final correction = _comparisonOffset - (_comparisonStart - _start);
    final entry = compare ? _comparisonEntry! : _selected!;
    if (compare) {
      entry['start'] = value;
    } else {
      _start = value;
    }
    entry['syncStatus'] = status;
    if (_comparisonPath != null) {
      _comparisonOffset = _comparisonStart - _start + correction;
    }
  }

  Future<void> _analyze({bool compare = false, bool automatic = false}) async {
    if (_selected == null || _analyzing) return;
    final generation = _openGeneration;
    final entry = compare ? _comparisonEntry : _selected;
    if (entry == null) return;
    _changed(() => _analyzing = true);
    await _player?.pause();
    await _comparison?.pause();
    try {
      final raw = await const MethodChannel('pace/audio')
          .invokeListMethod<dynamic>('analyze', {'path': entry['path']});
      final frames = (raw ?? []).map((e) {
        final a = e as List;
        return AudioFrame(
          (a[0] as num).toDouble(),
          (a[1] as num).toDouble(),
          (a[2] as num).toDouble(),
          a.length > 3 ? (a[3] as num).toDouble() : null,
        );
      }).toList();
      final result = analyzeAudio(frames);
      if (!mounted ||
          generation != _openGeneration ||
          (compare ? _comparisonEntry : _selected) != entry) {
        return;
      }
      _changed(() {
        final start = result.beep ?? (compare ? _comparisonStart : _start);
        final candidates = result.shotCandidates
            .where((t) => t > start)
            .toList();
        entry['beepCandidates'] = result.candidates
            .map(
              (candidate) => <String, dynamic>{
                'time': candidate.time,
                'atBoundary': candidate.atBoundary,
              },
            )
            .toList();
        final status = result.beep != null ? 'detected' : 'missing';
        _updateStart(compare, start, status);
        if (compare) {
          entry['candidates'] = candidates;
        } else {
          _candidates = candidates;
        }
        _notice = result.beep == null
            ? result.candidates.isEmpty
                  ? 'Сигнал не найден. Укажите время старта. Найденные выстрелы нужно подтвердить.'
                  : 'Старт требует подтверждения: сигнал обрезан или рядом найдены разные тоны. Выберите сигнал или укажите время старта.'
            : 'Возможный старт ${compare ? 'B' : 'A'}: ${start.toStringAsFixed(2)} с. Проверьте сигнал и кандидаты выстрелов.';
      });
      if (result.beep == null && mounted && !automatic) {
        final value = await _number(
          'Время старта ${compare ? 'B' : 'A'} в видео',
          compare ? _comparisonStart : _start,
        );
        final length =
            (compare ? _comparison : _player)?.value.duration.inMilliseconds ??
            0;
        if (!mounted || generation != _openGeneration) return;
        if (value != null && value >= -600 && value <= length / 1000) {
          _changed(() => _updateStart(compare, value, 'manual'));
        }
      }
      await _save();
    } on MissingPluginException {
      _message('Автоанализ доступен в Android-сборке. Укажите старт вручную.');
    } catch (error) {
      _message('Аудиоанализ недоступен: $error. Укажите старт вручную.');
    } finally {
      if (mounted) _changed(() => _analyzing = false);
    }
  }

  Future<double?> _number(String title, double initial) async {
    var input = initial.toStringAsFixed(2);
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: input,
          onChanged: (value) => input = value,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(labelText: 'Секунды'),
          onFieldSubmitted: (text) {
            final value = double.tryParse(text.replaceAll(',', '.'));
            if (value != null && value.isFinite) Navigator.pop(context, value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(input.replaceAll(',', '.'));
              if (value != null && value.isFinite) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    return value;
  }

  Run? get _run {
    for (final run in widget.runs) {
      if (run.id == _runId) return run;
    }
    return null;
  }

  String _runLabel(Run run) {
    final names = widget.shooters.where((s) => s.id == run.shooterId);
    return '${names.isEmpty ? 'Без стрелка' : names.first.name} · ${run.times.length} выстр. · ${run.totalTime.toStringAsFixed(2)} с';
  }

  Map<String, dynamic>? get _comparisonEntry {
    for (final entry in _videos) {
      if (entry['path'] == _comparisonPath) return entry;
    }
    return null;
  }

  double get _comparisonStart =>
      (_comparisonEntry?['start'] as num? ?? 0).toDouble();

  Run? get _comparisonRun {
    for (final run in widget.runs) {
      if (run.id == _comparisonEntry?['runId']) return run;
    }
    return null;
  }

  List<double> _times({bool compare = false, bool includeCandidates = false}) {
    final entry = _comparisonEntry;
    return videoShotTimes(
      start: compare ? _comparisonStart : _start,
      timerTimes: compare ? _comparisonRun?.times : _run?.times,
      markers: compare
          ? (entry?['markers'] as List? ?? [])
                .map((v) => (v as num).toDouble())
                .toList()
          : _markers,
      candidates: !includeCandidates
          ? const []
          : compare
          ? (entry?['candidates'] as List? ?? [])
                .map((v) => (v as num).toDouble())
                .toList()
          : _candidates,
    );
  }

  String _label({bool compare = false}) {
    final run = compare ? _comparisonRun : _run;
    if (run != null) {
      final names = widget.shooters.where((s) => s.id == run.shooterId);
      return names.isEmpty ? 'Без стрелка' : names.first.name;
    }
    return (compare ? _comparisonEntry : _selected)?['name'] as String? ??
        'Без видео';
  }

  Future<void> _pauseAndSeek(double seconds) async {
    await _player?.pause();
    await _comparison?.pause();
    await _seek(seconds);
  }

  Future<void> _setStart(
    bool compare, {
    bool here = false,
    bool firstShot = false,
    double? candidate,
  }) async {
    final player = compare ? _comparison : _player;
    if (player == null) return;
    final position = player.value.position.inMilliseconds / 1000;
    final times = _times(compare: compare);
    final value =
        candidate ??
        (here
            ? position - (firstShot && times.isNotEmpty ? times.first : 0)
            : await _number(
                'Время стартового сигнала ${compare ? 'B' : 'A'}',
                compare ? _comparisonStart : _start,
              ));
    if (value == null ||
        !mounted ||
        value < -600 ||
        value > player.value.duration.inMilliseconds / 1000) {
      if (value != null) {
        _message(
          'Укажите время от −600 с до конца видео. Отрицательное время означает старт до записи.',
        );
      }
      return;
    }
    await _player?.pause();
    await _comparison?.pause();
    _changed(() {
      _calibrating = null;
      _updateStart(compare, value, 'manual');
    });
    await _persist();
    await _seek(_readyToCompare ? _playStartPosition : _position);
  }

  Future<void> _export({bool compare = false, bool sideBySide = false}) async {
    if (_selected == null || _exporting || _busy || _opening || _analyzing) {
      return;
    }
    await _player?.pause();
    await _comparison?.pause();
    _changed(() => _exporting = true);
    try {
      final path = await const MethodChannel('pace/audio')
          .invokeMethod<String>('exportAnalysis', {
            'primaryPath': compare
                ? Uri.parse(_player!.dataSource).toFilePath()
                : _selected!['path'],
            'start': _start,
            'times': _times(includeCandidates: true),
            'primaryLabel': 'A · ${_label()}',
            'mode': compare
                ? (_overlay && !sideBySide ? 'overlay' : 'sideBySide')
                : 'single',
            if (compare) ...{
              'comparisonPath': Uri.parse(_comparison!.dataSource).toFilePath(),
              'comparisonStart': _comparisonStart,
              'comparisonTimes': _times(compare: true, includeCandidates: true),
              'comparisonLabel': 'B · ${_label(compare: true)}',
              'comparisonCorrection':
                  _comparisonOffset - (_comparisonStart - _start),
              'opacity': _opacity,
            },
          });
      if (path == null || !await File(path).exists()) {
        throw StateError('Файл экспорта не создан');
      }
      if (!mounted) return;
      _message('Видео с анализом сохранено. Выберите, куда отправить файл.');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_notice)));
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'video/mp4')],
          text: 'PACE · Видеоразбор',
        ),
      );
    } on PlatformException catch (error) {
      _message('Не удалось экспортировать видео: ${error.message}');
    } on MissingPluginException {
      _message('Для экспорта установите новую Android-сборку PACE.');
    } catch (error) {
      _message('Ошибка экспорта: $error');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_notice)));
      }
    } finally {
      if (mounted) _changed(() => _exporting = false);
    }
  }

  Widget _hud(VideoPlayerController controller, {required bool compare}) {
    final relative =
        controller.value.position.inMilliseconds / 1000 -
        (compare ? _comparisonStart : _start);
    final elapsed = relative.abs() < .001 ? 0.0 : relative;
    final times = _times(compare: compare, includeCandidates: true);
    final index = videoShotIndex(times, elapsed);
    final shotTime = index >= 0 ? '${times[index].toStringAsFixed(2)} с' : '—';
    final split = index >= 0
        ? '${videoSplit(times, index).toStringAsFixed(2)} с'
        : '—';
    return Container(
      key: ValueKey(compare ? 'video-hud-b' : 'video-hud-a'),
      padding: const EdgeInsets.all(6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${compare ? 'B' : 'A'} · ${_label(compare: compare)}\n',
              style: const TextStyle(fontSize: 12),
            ),
            TextSpan(text: shotTime, style: const TextStyle(fontSize: 26)),
            TextSpan(text: '  №${index + 1}/${times.length}\n'),
            TextSpan(text: 'Сплит: $split'),
          ],
        ),
        textAlign: compare ? TextAlign.right : TextAlign.left,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          fontFeatures: [FontFeature.tabularFigures()],
          shadows: [
            Shadow(color: Colors.black, blurRadius: 3),
            Shadow(color: Colors.black, offset: Offset(1, 1), blurRadius: 2),
          ],
        ),
      ),
    );
  }

  Widget _playerSettings() => PopupMenuButton<double>(
    tooltip: 'Настройки плеера',
    icon: const Icon(Icons.settings, color: Colors.white),
    itemBuilder: (_) => [
      for (final speed in [.25, .5, 1.0])
        CheckedPopupMenuItem(
          value: speed,
          checked: _speed == speed,
          child: Text('Скорость $speed×'),
        ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem(
        value: -1,
        checked: !_mutedA,
        child: const Text('Звук A'),
      ),
      if (_comparison != null)
        CheckedPopupMenuItem(
          value: -2,
          checked: !_mutedB,
          child: const Text('Звук B'),
        ),
      const PopupMenuItem(value: -3, child: Text('Предыдущий кадр')),
      const PopupMenuItem(value: -4, child: Text('Следующий кадр')),
      const PopupMenuItem(value: -5, child: Text('К сигналам таймеров')),
    ],
    onSelected: (value) async {
      if (value == -1 || value == -2) {
        final compare = value == -2;
        final player = compare ? _comparison! : _player!;
        final muted = player.value.volume != 0;
        _changed(() {
          if (compare) {
            _mutedB = muted;
          } else {
            _mutedA = muted;
          }
        });
        await player.setVolume(muted ? 0 : 1);
      } else if (value == -3 || value == -4) {
        await _pauseAndSeek(
          _position + (value == -3 ? -_frameStep : _frameStep),
        );
      } else if (value == -5) {
        if (_readyToCompare) await _fromStart();
      } else {
        _changed(() => _speed = value);
        await Future.wait([
          _player!.setPlaybackSpeed(value),
          if (_comparison != null) _comparison!.setPlaybackSpeed(value),
        ]);
      }
    },
  );

  Widget _exportAction({bool sideBySide = false}) => IconButton(
    tooltip: _comparison == null
        ? 'Экспорт видео A с анализом'
        : 'Экспорт сравнения A и B',
    color: Colors.white,
    style: IconButton.styleFrom(backgroundColor: Colors.black54),
    onPressed: _exporting || _busy || _opening || _analyzing
        ? null
        : () => _export(compare: _comparison != null, sideBySide: sideBySide),
    icon: const Icon(Icons.ios_share),
  );

  Widget _video(
    VideoPlayerController controller, {
    required bool compare,
    bool fullscreen = false,
  }) {
    final picture = AspectRatio(
      aspectRatio: controller.value.aspectRatio > 0
          ? controller.value.aspectRatio
          : 16 / 9,
      child: VideoPlayer(controller),
    );
    return Stack(
      fit: fullscreen ? StackFit.expand : StackFit.loose,
      children: [
        if (fullscreen) Center(child: picture) else picture,
        Positioned(
          left: 4,
          right: 4,
          bottom: 4,
          child: _hud(controller, compare: compare),
        ),
      ],
    );
  }

  Widget _viewer({bool fullscreen = false}) {
    final player = _player!;
    if (_comparison == null) {
      return _video(player, compare: false, fullscreen: fullscreen);
    }
    if (_overlay) {
      return LayoutBuilder(
        builder: (context, box) {
          final ratio = player.value.aspectRatio > 0
              ? player.value.aspectRatio
              : 16 / 9;
          final width =
              box.hasBoundedHeight && box.maxHeight * ratio < box.maxWidth
              ? box.maxHeight * ratio
              : box.maxWidth;
          return AspectRatio(
            aspectRatio: ratio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: player.value.size.width,
                    height: player.value.size.height,
                    child: VideoPlayer(player),
                  ),
                ),
                Opacity(
                  opacity: _opacity,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: _comparison!.value.size.width,
                      height: _comparison!.value.size.height,
                      child: VideoPlayer(_comparison!),
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: SizedBox(
                    width: (width / 2 - 8).clamp(1, 240),
                    child: _hud(player, compare: false),
                  ),
                ),
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: SizedBox(
                    width: (width / 2 - 8).clamp(1, 240),
                    child: _hud(_comparison!, compare: true),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!fullscreen && constraints.maxWidth < 600) {
          return Column(
            children: [
              _video(player, compare: false),
              const SizedBox(height: 4),
              _video(_comparison!, compare: true),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _video(player, compare: false, fullscreen: fullscreen),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _video(
                _comparison!,
                compare: true,
                fullscreen: fullscreen,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _transport({bool fullscreen = false}) {
    final player = _player!;
    final elapsed = _position - _start;
    final times = {
      ..._times(includeCandidates: true),
      if (_comparison != null)
        ..._times(
          compare: true,
          includeCandidates: true,
        ).map((t) => t - (_comparisonOffset - (_comparisonStart - _start))),
    }.toList()..sort();
    final previous = times.where((t) => t < elapsed - .005).toList();
    final next = times.where((t) => t > elapsed + .005).toList();
    final controls = <Widget>[
      IconButton(
        tooltip: 'Предыдущий выстрел',
        onPressed: previous.isEmpty
            ? null
            : () => _pauseAndSeek(_start + previous.last),
        icon: const Icon(Icons.skip_previous),
      ),
      IconButton.filled(
        key: const ValueKey('paired-play'),
        tooltip: player.value.isPlaying ? 'Пауза' : 'Пуск',
        onPressed: _readyToCompare && !_opening && !_analyzing ? _play : null,
        icon: Icon(player.value.isPlaying ? Icons.pause : Icons.play_arrow),
      ),
      IconButton(
        tooltip: 'Следующий выстрел',
        onPressed: next.isEmpty
            ? null
            : () => _pauseAndSeek(_start + next.first),
        icon: const Icon(Icons.skip_next),
      ),
      _playerSettings(),
      if (fullscreen)
        _exportAction(sideBySide: !_overlay)
      else
        IconButton(
          tooltip: 'Полноэкранный разбор',
          onPressed: _fullscreen,
          icon: const Icon(Icons.fullscreen),
        ),
    ];
    return Theme(
      data: Theme.of(context).copyWith(
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: Colors.white,
            disabledForegroundColor: Colors.white38,
            padding: const EdgeInsets.all(8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          key: const ValueKey('video-player-controls'),
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          spacing: 4,
          children: controls,
        ),
      ),
    );
  }

  Widget _timeline() {
    final duration = (_endPosition - _start).clamp(.001, double.infinity);
    return ShotTimeline(
      duration: duration,
      position: (_position - _start).clamp(0, duration),
      primaryTimes: _times(includeCandidates: true),
      comparisonTimes: _comparison == null
          ? const []
          : _times(compare: true, includeCandidates: true)
                .map(
                  (t) => t - (_comparisonOffset - (_comparisonStart - _start)),
                )
                .toList(),
      onSeek: (value) => _pauseAndSeek(_start + value),
    );
  }

  Widget _splitTable() {
    final a = _times(includeCandidates: true);
    final b = _comparison == null
        ? <double>[]
        : _times(compare: true, includeCandidates: true);
    final count = a.length > b.length ? a.length : b.length;
    if (count == 0) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'Выберите проход таймера или подтвердите выстрелы из аудио.',
        ),
      );
    }
    String time(List<double> values, int i, {bool split = false}) =>
        i >= values.length
        ? '—'
        : (split ? videoSplit(values, i) : values[i]).toStringAsFixed(2);
    final active = videoShotIndex(a, _position - _start);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Выстрелы и сплиты',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Время и сплит в секундах. Δ = время B − A: «+» означает, что B позже. Нажмите строку, чтобы перейти к выстрелу.',
        ),
        if (b.isNotEmpty)
          const Text(
            'Сравнение по номеру выстрела. При разном порядке мишеней соответствие проверяет тренер.',
          ),
        SizedBox(
          height: (64 + count * 56.0).clamp(120, 360),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                showCheckboxColumn: false,
                columnSpacing: 16,
                horizontalMargin: 12,
                columns: [
                  const DataColumn(label: Text('№')),
                  const DataColumn(label: Text('A · время')),
                  const DataColumn(label: Text('A · сплит')),
                  if (b.isNotEmpty) ...[
                    const DataColumn(label: Text('B · время')),
                    const DataColumn(label: Text('B · сплит')),
                    const DataColumn(label: Text('Δ, с')),
                  ],
                ],
                rows: List.generate(
                  count,
                  (i) => DataRow(
                    selected: i == active,
                    onSelectChanged: (_) => _pauseAndSeek(
                      _start +
                          (i < a.length
                              ? a[i]
                              : b[i] -
                                    (_comparisonOffset -
                                        (_comparisonStart - _start))),
                    ),
                    cells: [
                      DataCell(Text('${i + 1}')),
                      DataCell(Text(time(a, i))),
                      DataCell(Text(time(a, i, split: true))),
                      if (b.isNotEmpty) ...[
                        DataCell(Text(time(b, i))),
                        DataCell(Text(time(b, i, split: true))),
                        DataCell(
                          Text(
                            i < a.length && i < b.length
                                ? '${b[i] - a[i] >= 0 ? '+' : ''}${(b[i] - a[i]).toStringAsFixed(2)}'
                                : '—',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _fullscreen() async {
    if (_fullscreenOpen) return;
    _fullscreenOpen = true;
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xffd65320),
                brightness: Brightness.dark,
              ),
              iconButtonTheme: IconButtonThemeData(
                style: IconButton.styleFrom(
                  minimumSize: const Size(56, 56),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white38,
                ),
              ),
            ),
            child: Scaffold(
              backgroundColor: Colors.black,
              body: SafeArea(
                child: AnimatedBuilder(
                  animation: _revision,
                  builder: (context, _) => Stack(
                    children: [
                      Column(
                        children: [
                          Expanded(child: _viewer(fullscreen: true)),
                          if (_exporting) ...[
                            const LinearProgressIndicator(),
                            TextButton(
                              onPressed: () => const MethodChannel('pace/audio')
                                  .invokeMethod<void>('cancelExportAnalysis'),
                              child: const Text('Отменить экспорт'),
                            ),
                          ],
                          SizedBox(
                            height: 48,
                            child: Slider(
                              label:
                                  '${(_position - _start).toStringAsFixed(2)} с',
                              semanticFormatterCallback: (value) =>
                                  '${(value - _start).toStringAsFixed(2)} секунды от старта',
                              value: _position.clamp(0, _endPosition),
                              min: 0,
                              max: _endPosition > 0 ? _endPosition : .001,
                              onChanged: _pauseAndSeek,
                            ),
                          ),
                          _transport(fullscreen: true),
                        ],
                      ),
                      Positioned(
                        top: 4,
                        left: 4,
                        child: IconButton(
                          tooltip: 'Закрыть полный экран',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black54,
                          ),
                          color: Colors.white,
                          icon: const Icon(Icons.fullscreen_exit),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      _fullscreenOpen = false;
      await SystemChrome.setPreferredOrientations([]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Widget _runPicker({bool compare = false}) {
    final runId = compare ? _comparisonRun?.id : _runId;
    return DropdownButtonFormField<String>(
      key: ValueKey(
        'run:${compare ? _comparisonPath : _selected?['path']}:$runId',
      ),
      initialValue: runId ?? '',
      isExpanded: true,
      decoration: InputDecoration(labelText: 'Проход ${compare ? 'B' : 'A'}'),
      items: [
        const DropdownMenuItem(
          value: '',
          child: Text('Без таймера · метки по видео'),
        ),
        ...widget.runs.map(
          (r) => DropdownMenuItem(
            value: r.id,
            child: Text(_runLabel(r), overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: _exporting
          ? null
          : (value) async {
              _changed(() {
                if (compare) {
                  _comparisonEntry!['runId'] = value == '' ? null : value;
                } else {
                  _runId = value == '' ? null : value;
                }
              });
              await _persist();
            },
    );
  }

  Future<void> _analyzeBoth() async {
    if (_opening || _analyzing || _exporting) return;
    await _analyze(automatic: true);
    if (_comparison != null) await _analyze(compare: true, automatic: true);
    if (_readyToCompare) await _seek(_playStartPosition);
  }

  Widget _syncControls({bool compare = false}) {
    final controller = compare ? _comparison : _player;
    final entry = compare ? _comparisonEntry : _selected;
    final calibration = _calibrating == compare;
    final label = compare ? 'B' : 'A';
    final duration = (controller?.value.duration.inMilliseconds ?? 0) / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Старт $label · ${_hasStart(entry) ? '${(compare ? _comparisonStart : _start).toStringAsFixed(2)} с · ${entry?["syncStatus"] == "detected" ? "найден по звуку" : "ручная отметка"}' : 'не найден'}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          'Проверьте писк таймера на слух. Если запись началась позже, выберите проход и отметьте первый выстрел: старт может получиться отрицательным.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _opening || _analyzing
                  ? null
                  : () => _analyze(compare: compare),
              child: const Text('Найти сигнал и выстрелы'),
            ),
            OutlinedButton.icon(
              onPressed: _opening || _analyzing
                  ? null
                  : () => _calibrate(compare),
              icon: const Icon(Icons.hearing),
              label: Text('Проверить старт $label'),
            ),
            OutlinedButton(
              onPressed: () => _setStart(compare),
              child: Text(
                'Старт: ${(compare ? _comparisonStart : _start).toStringAsFixed(2)} с',
              ),
            ),
            OutlinedButton(
              onPressed: () => _setStart(compare, here: true),
              child: const Text('Сигнал здесь'),
            ),
            if ((compare ? _comparisonRun : _run)?.times.isNotEmpty == true)
              OutlinedButton(
                onPressed: () =>
                    _setStart(compare, here: true, firstShot: true),
                child: const Text('Первый выстрел здесь'),
              ),
          ],
        ),
        if ((entry?['beepCandidates'] as List? ?? []).isNotEmpty) ...[
          const Text('Найденные сигналы · выберите после прослушивания'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final candidate in entry!['beepCandidates'] as List)
                OutlinedButton(
                  onPressed: () => _setStart(
                    compare,
                    candidate: (candidate['time'] as num).toDouble(),
                  ),
                  child: Text(
                    '${(candidate['time'] as num).toStringAsFixed(2)} с${candidate['atBoundary'] == true ? ' · начало обрезано' : ''}',
                  ),
                ),
            ],
          ),
          if ((entry['beepCandidates'] as List).any(
            (candidate) => candidate['atBoundary'] == true,
          ))
            const Text(
              'Запись начинается во время сигнала: его настоящее начало может быть раньше видео. Для точной привязки используйте первый выстрел и времена внешнего таймера.',
            ),
        ],
        if (calibration && controller != null) ...[
          Text(
            'Сейчас звучит только $label · ${(controller.value.position.inMilliseconds / 1000).toStringAsFixed(2)} с от начала файла',
          ),
          Slider(
            value: (controller.value.position.inMilliseconds / 1000).clamp(
              0,
              duration,
            ),
            max: duration > 0 ? duration : 1,
            onChanged: (value) async {
              await controller.pause();
              await controller.seekTo(
                Duration(milliseconds: (value * 1000).round()),
              );
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => controller.value.isPlaying
                    ? controller.pause()
                    : controller.play(),
                icon: Icon(
                  controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                label: Text(
                  controller.value.isPlaying
                      ? 'Пауза $label'
                      : 'Слушать $label',
                ),
              ),
              TextButton(
                onPressed: () async {
                  await controller.pause();
                  _changed(() => _calibrating = null);
                  if (_readyToCompare) await _fromStart();
                },
                child: const Text('К общему просмотру'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _videoSetup({bool compare = false}) {
    final entry = compare ? _comparisonEntry : _selected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Видео ${compare ? 'B' : 'A'}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _hasStart(entry)
                      ? Icons.check_circle_outline
                      : Icons.sync_problem,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _hasStart(entry)
                        ? 'Старт задан · ${(compare ? _comparisonStart : _start).toStringAsFixed(2)} с от начала видео'
                        : 'Старт не задан · найдите сигнал или отметьте вручную',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _runPicker(compare: compare),
            const SizedBox(height: 16),
            _syncControls(compare: compare),
            _manualEditor(compare: compare),
          ],
        ),
      ),
    );
  }

  Widget _manualEditor({bool compare = false}) {
    final entry = compare ? _comparisonEntry : _selected;
    if (entry == null || (compare ? _comparisonRun : _run) != null) {
      return const SizedBox.shrink();
    }
    final start = compare ? _comparisonStart : _start;
    final controller = compare ? _comparison : _player;
    if (controller == null) return const SizedBox.shrink();
    final duration = controller.value.duration.inMilliseconds / 1000;
    final markers = compare
        ? (entry['markers'] as List? ?? [])
              .map((v) => (v as num).toDouble())
              .toList()
        : _markers;
    final candidates = compare
        ? (entry['candidates'] as List? ?? [])
              .map((v) => (v as num).toDouble())
              .toList()
        : _candidates;
    Future<void> save() async {
      _changed(() {
        if (compare) {
          entry['markers'] = markers;
          entry['candidates'] = candidates;
        } else {
          _markers = markers;
          _candidates = candidates;
        }
      });
      await _persist();
    }

    Future<void> seek(double value) =>
        _pauseAndSeek(compare ? value - _comparisonOffset : value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Text(
          'Метки ${compare ? 'B' : 'A'} · ${markers.length} подтверждено · ${candidates.length} кандидатов',
        ),
        const Text(
          'Автопоиск может принять эхо, речь и лязг за выстрел. Прослушайте кандидаты и подтвердите нужные.',
        ),
        FilledButton.tonal(
          onPressed: () async {
            final position = controller.value.position.inMilliseconds / 1000;
            if (position < start) {
              _message('Выстрел должен быть после старта.');
              return;
            }
            if (markers.any((t) => (t - position).abs() < .01)) return;
            markers.add(position);
            markers.sort();
            await save();
          },
          child: const Text('Добавить выстрел здесь'),
        ),
        for (var i = 0; i < markers.length; i++)
          ListTile(
            title: Text(
              'Выстрел ${i + 1} · ${(markers[i] - start).toStringAsFixed(2)} с',
            ),
            onTap: () => seek(markers[i]),
            leading: IconButton(
              tooltip: 'Изменить метку',
              icon: const Icon(Icons.edit),
              onPressed: () async {
                final value = await _number(
                  'Время выстрела в видео',
                  markers[i],
                );
                if (value == null || value < start || value > duration) return;
                markers[i] = value;
                markers.sort();
                await save();
              },
            ),
            trailing: IconButton(
              tooltip: 'Удалить метку',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                markers.removeAt(i);
                await save();
              },
            ),
          ),
        for (final time in candidates)
          ListTile(
            title: Text('Кандидат · ${time.toStringAsFixed(2)} с'),
            onTap: () => seek((time - .3).clamp(0, duration)),
            leading: IconButton(
              tooltip: 'Подтвердить выстрел',
              icon: const Icon(Icons.check),
              onPressed: () async {
                if (time < start) {
                  _message('Кандидат находится до старта.');
                  return;
                }
                if (!markers.any((t) => (t - time).abs() < .01)) {
                  markers.add(time);
                }
                markers.sort();
                candidates.remove(time);
                await save();
              },
            ),
            trailing: IconButton(
              tooltip: 'Отклонить кандидата',
              icon: const Icon(Icons.close),
              onPressed: () async {
                candidates.remove(time);
                await save();
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final children = <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed:
                _busy || _opening || _analyzing || _exporting || !_metadataReady
                ? null
                : () => _import(ImageSource.gallery),
            icon: const Icon(Icons.video_library),
            label: const Text('Выбрать видео'),
          ),
        ],
      ),
      if (_busy || _opening || _analyzing || _exporting)
        const LinearProgressIndicator(),
      if (_opening)
        const Text(
          'Готовим плавный просмотр. Для 4K/HEVC первая подготовка займёт время; исходник сохраняется.',
        ),
      if (_analyzing) const Text('Ищем сигнал таймера по звуку…'),
      if (_exporting)
        Row(
          children: [
            const Expanded(child: Text('Создаём MP4 с анализом…')),
            TextButton(
              onPressed: () =>
                  const MethodChannel('pace/audio')
                      .invokeMethod<void>('cancelExportAnalysis'),
              child: const Text('Отмена'),
            ),
          ],
        ),
      const SizedBox(height: 16),
      if (_videos.isNotEmpty)
        DropdownButtonFormField<String>(
          key: ValueKey('video:${_selected?['path']}'),
          initialValue: _selected?['path'] as String?,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Видео A'),
          items: _videos
              .map(
                (v) => DropdownMenuItem(
                  value: v['path'] as String,
                  child: Text(
                    v['name'] as String,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: _busy || _opening || _analyzing || _exporting
              ? null
              : (path) {
                  if (path != null) {
                    _open(_videos.firstWhere((v) => v['path'] == path));
                  }
                },
        ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(_notice),
      ),
      if (_loadFailed)
        OutlinedButton(
          onPressed: _load,
          child: const Text('Повторить чтение списка видео'),
        ),
      if (player != null) ...[
        Text(
          'Сравнить с видео B',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('comparison:${_selected?['path']}:$_comparisonPath'),
          initialValue: _videos.any((v) => v['path'] == _comparisonPath)
              ? _comparisonPath
              : null,
          decoration: const InputDecoration(labelText: 'Видео B'),
          isExpanded: true,
          items: _videos
              .map(
                (v) => DropdownMenuItem(
                  value: v['path'] as String,
                  child: Text(
                    v['name'] as String,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: _busy || _opening || _analyzing || _exporting
              ? null
              : (path) {
                  if (path != null) _openComparison(path);
                },
        ),
        OutlinedButton(
          onPressed: _busy || _opening || _analyzing || _exporting
              ? null
              : () => _import(ImageSource.gallery, compare: true),
          child: const Text('Добавить видео B из галереи'),
        ),
        Text(
          _readyToCompare
              ? 'Общий старт 0.00 с · A: ${_start.toStringAsFixed(2)} с${_comparison != null ? ' · B: ${_comparisonStart.toStringAsFixed(2)} с' : ''}'
              : 'Для запуска от таймера найдите старт ${!_hasStart(_selected) ? 'A' : 'B'}.',
        ),
        OutlinedButton.icon(
          onPressed: _opening || _analyzing || _exporting ? null : _analyzeBoth,
          icon: const Icon(Icons.auto_fix_high),
          label: Text(
            _comparison == null ? 'Найти старт по звуку' : 'Найти старты A и B',
          ),
        ),
        if (_readyToCompare && _playStartPosition > _start + .01)
          Text(
            'Начало записи обрезано: общий доступный участок с ${(_playStartPosition - _start).toStringAsFixed(2)} с после сигнала.',
          ),
        _viewer(),
        _timeline(),
        _transport(),
        _splitTable(),
        const Divider(),
        if (_comparison != null) ...[
          LayoutBuilder(
            builder: (context, constraints) => SegmentedButton<bool>(
              direction:
                  constraints.maxWidth < 340 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.3
                  ? Axis.vertical
                  : Axis.horizontal,
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Рядом'),
                  icon: Icon(Icons.view_column),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Наложение'),
                  icon: Icon(Icons.layers),
                ),
              ],
              selected: {_overlay},
              onSelectionChanged: (v) async {
                _changed(() => _overlay = v.first);
                await _persist();
              },
            ),
          ),
          if (_overlay) ...[
            Text('Прозрачность B: ${(_opacity * 100).round()}%'),
            Slider(
              value: _opacity,
              min: 0,
              max: 1,
              divisions: 10,
              onChanged: (v) => _changed(() => _opacity = v),
              onChangeEnd: (_) => _persist(),
            ),
          ],
          TextButton(
            onPressed: () async {
              final old = _comparison;
              _comparisonGeneration++;
              _changed(() {
                _comparison = null;
                _comparisonPath = null;
                _comparisonOffset = 0;
              });
              await old?.dispose();
              await _persist();
            },
            child: const Text('Убрать B из сравнения'),
          ),
        ],
        const Divider(),
        FilledButton.icon(
          onPressed: _exporting || _busy || _opening || _analyzing
              ? null
              : _export,
          icon: const Icon(Icons.ios_share),
          label: const Text('Экспорт видео A с анализом'),
        ),
        const Text(
          'MP4 с временем, номером выстрела и сплитом. Исходное видео сохраняется.',
        ),
        if (_comparison != null) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _exporting || _busy || _opening || _analyzing
                ? null
                : () => _export(compare: true),
            icon: const Icon(Icons.video_file),
            label: Text(
              _overlay ? 'Экспорт наложения A + B' : 'Экспорт сравнения A и B',
            ),
          ),
          const Text(
            'Общий старт, до конца более короткого ролика. Звук из A. Качество просмотра: до 720p на ролик, исходники сохраняются.',
          ),
        ],
        const SizedBox(height: 8),
        ExpansionTile(
          key: const PageStorageKey('video-manual-settings'),
          title: const Text('Ручная синхронизация и выстрелы'),
          childrenPadding: const EdgeInsets.only(top: 8),
          children: [
            _videoSetup(),
            if (_comparison != null) ...[
              _videoSetup(compare: true),
              OutlinedButton(
                onPressed: () async {
                  final value = await _number(
                    'Точная поправка B относительно общего старта',
                    _comparisonOffset - (_comparisonStart - _start),
                  );
                  if (value == null || !mounted) return;
                  _changed(
                    () => _comparisonOffset = _comparisonStart - _start + value,
                  );
                  await _persist();
                  await _seek(_position);
                },
                child: Text(
                  'Поправка B: ${(_comparisonOffset - (_comparisonStart - _start)).toStringAsFixed(2)} с',
                ),
              ),
            ],
          ],
        ),
        _splitTable(),
      ],
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ],
    );
  }

  @override
  void dispose() {
    ++_openGeneration;
    ++_comparisonGeneration;
    _player?.removeListener(_tick);
    _comparison?.removeListener(_comparisonTick);
    unawaited(
      const MethodChannel('pace/audio')
          .invokeMethod<void>('cancelVideoPreview')
          .catchError((Object _) {}),
    );
    _revision.dispose();
    _player?.dispose();
    _comparison?.dispose();
    super.dispose();
  }
}
