import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'domain.dart';

const _maxBytes = 5 * 1024 * 1024;

class MatchArchive {
  final String id;
  final DateTime createdAt;
  final List<String> stageIds;
  final List<String> excludedShooterIds;
  MatchArchive({
    required this.id,
    required this.createdAt,
    required List<String> stageIds,
    List<String> excludedShooterIds = const [],
  }) : stageIds = List.unmodifiable(stageIds),
       excludedShooterIds = List.unmodifiable(excludedShooterIds);
  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'stageIds': stageIds,
    'excludedShooterIds': excludedShooterIds,
  };
  factory MatchArchive.fromJson(Map<String, dynamic> j) {
    final ids = j['stageIds'];
    final excluded = j['excludedShooterIds'] ?? <dynamic>[];
    if (excluded is! List ||
        excluded.length > 1000 ||
        excluded.any((v) => v is! String || v.isEmpty) ||
        excluded.toSet().length != excluded.length) {
      throw const FormatException('Invalid archived participants');
    }
    final date = j['createdAt'] is String
        ? DateTime.tryParse(j['createdAt'])
        : null;
    if (j['id'] is! String ||
        (j['id'] as String).isEmpty ||
        date == null ||
        ids is! List ||
        ids.isEmpty ||
        ids.any((v) => v is! String || v.isEmpty) ||
        ids.toSet().length != ids.length) {
      throw const FormatException('Invalid match archive');
    }
    return MatchArchive(
      id: j['id'],
      createdAt: date,
      stageIds: ids.cast<String>(),
      excludedShooterIds: excluded.cast<String>(),
    );
  }
}

class AppData {
  final List<Shooter> shooters;
  final Set<String> matchExcludedShooters;
  List<Shooter> get matchShooters =>
      shooters.where((s) => !matchExcludedShooters.contains(s.id)).toList();
  final List<Stage> stages;
  final List<Stage> archivedStages;
  final List<MatchArchive> archivedMatches;
  List<Stage> get allStages => [...archivedStages, ...stages];
  List<Run> get matchRuns => runs
      .where(
        (r) =>
            !matchExcludedShooters.contains(r.shooterId) &&
            stages.any((s) => s.id == r.stageId),
      )
      .toList();

  void selectFirstPasses() {
    final groups = <String, List<int>>{};
    for (var i = 0; i < runs.length; i++) {
      final r = runs[i];
      if (r.shooterId != null && r.stageId != null) {
        groups.putIfAbsent("${r.shooterId}/${r.stageId}", () => []).add(i);
      }
    }
    for (final indices in groups.values) {
      if (!indices.any((i) => runs[i].selected)) {
        indices.sort((a, b) => runs[a].createdAt.compareTo(runs[b].createdAt));
        runs[indices.first] = runs[indices.first].copyWith(selected: true);
      }
    }
  }

  void newMatch() {
    if (stages.isNotEmpty) {
      final now = DateTime.now();
      archivedMatches.add(
        MatchArchive(
          id: 'match-${now.microsecondsSinceEpoch}',
          createdAt: now,
          stageIds: stages.map((s) => s.id).toList(),
          excludedShooterIds: matchExcludedShooters.toList(),
        ),
      );
    }
    archivedStages.addAll(stages);
    stages.clear();
    matchExcludedShooters.clear();
  }

  final List<Run> runs;
  final List<Run> calculations;
  final List<Map<String, dynamic>> revisions;
  AppData({
    List<Shooter> shooters = const [],
    Set<String> matchExcludedShooters = const {},
    List<Stage> stages = const [],
    List<Stage> archivedStages = const [],
    List<MatchArchive> archivedMatches = const [],
    List<Run> runs = const [],
    List<Run> calculations = const [],
    List<Map<String, dynamic>> revisions = const [],
  }) : shooters = List.of(shooters),
       matchExcludedShooters = Set.of(matchExcludedShooters),
       stages = List.of(stages),
       archivedStages = List.of(archivedStages),
       archivedMatches = List.of(archivedMatches),
       runs = List.of(runs),
       calculations = List.of(calculations),
       revisions = List.of(revisions);

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'shooters': shooters.map((s) => s.toJson()).toList(),
    'matchExcludedShooters': matchExcludedShooters.toList(),
    'stages': stages.map((s) => s.toJson()).toList(),
    'archivedStages': archivedStages.map((s) => s.toJson()).toList(),
    'archivedMatches': archivedMatches.map((s) => s.toJson()).toList(),
    'runs': runs.map((r) => r.toJson()).toList(),
    'calculations': calculations.map((r) => r.toJson()).toList(),
    'revisions': revisions,
  };

  factory AppData.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['schemaVersion'] is! int) {
      throw const FormatException('Unsupported data schema');
    }
    List<T> records<T>(
      String key,
      int max,
      T Function(Map<String, dynamic>) parse,
    ) {
      final value = json[key];
      if (value is! List || value.length > max) {
        throw FormatException('Invalid $key');
      }
      return value.map((item) {
        if (item is! Map<String, dynamic>) {
          throw FormatException('Invalid $key entry');
        }
        return parse(item);
      }).toList();
    }

    final excluded = json['matchExcludedShooters'] ?? <dynamic>[];
    if (excluded is! List ||
        excluded.length > 1000 ||
        excluded.any((v) => v is! String || v.isEmpty) ||
        excluded.toSet().length != excluded.length) {
      throw const FormatException('Invalid match participants');
    }
    final data = AppData(
      shooters: records('shooters', 1000, Shooter.fromJson),
      matchExcludedShooters: excluded.cast<String>().toSet(),
      stages: records('stages', 1000, Stage.fromJson),
      archivedStages: json.containsKey('archivedStages')
          ? records('archivedStages', 10000, Stage.fromJson)
          : [],
      archivedMatches: json.containsKey('archivedMatches')
          ? records('archivedMatches', 10000, MatchArchive.fromJson)
          : [],
      runs: records('runs', 100000, Run.fromJson),
      calculations: json.containsKey('calculations')
          ? records('calculations', 5, Run.fromJson)
          : [],
      revisions: records('revisions', 100000, (j) => j),
    );
    Set<String> unique(Iterable<String> ids) {
      final values = ids.toList();
      final set = values.toSet();
      if (set.length != values.length) {
        throw const FormatException('Duplicate ID');
      }
      return set;
    }

    final people = unique(data.shooters.map((s) => s.id));
    if (!people.containsAll(data.matchExcludedShooters)) {
      throw const FormatException('Missing excluded shooter');
    }
    final stages = unique(data.allStages.map((s) => s.id));
    final stageById = {for (final stage in data.allStages) stage.id: stage};
    unique(data.runs.map((r) => r.id));
    unique(data.calculations.map((r) => r.id));
    for (final run in data.runs) {
      if ((run.shooterId != null && !people.contains(run.shooterId)) ||
          (run.stageId != null && !stages.contains(run.stageId))) {
        throw const FormatException(
          'Run references a missing shooter or stage',
        );
      }
      if (run.selected && run.stageId != null && run.shooterId == null) {
        throw const FormatException('Selected stage run needs a shooter');
      }
      final stage = stageById[run.stageId];
      if (stage != null &&
          run.alpha + run.charlie + run.delta >
              stage.paper * stage.hitsPerPaper +
                  stage.steel * stage.hitsPerSteel) {
        throw const FormatException('Run hits exceed stage capacity');
      }
    }
    unique(data.archivedMatches.map((m) => m.id));
    final archivedIds = data.archivedStages.map((s) => s.id).toSet();
    final usedIds = <String>{};
    for (final match in data.archivedMatches) {
      for (final id in match.stageIds) {
        if (!archivedIds.contains(id) || !usedIds.add(id)) {
          throw const FormatException('Invalid archived stage reference');
        }
      }
    }
    final legacyIds = archivedIds.difference(usedIds);
    if (legacyIds.isNotEmpty) {
      var id = 'legacy-archive';
      while (data.archivedMatches.any((m) => m.id == id)) {
        id = '$id-1';
      }
      data.archivedMatches.insert(
        0,
        MatchArchive(
          id: id,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          stageIds: legacyIds.toList(),
        ),
      );
    }
    matchTotals(data.allStages, data.runs);
    data.selectFirstPasses();
    return data;
  }
}

class StoreException implements Exception {
  final String message;
  StoreException(this.message);
  @override
  String toString() => message;
}

/// One store per app. Writes are serialized and snapshots are taken when save is called.
class TrainingStore {
  final Directory? directory;
  Future<void> _pending = Future.value();
  TrainingStore({this.directory});

  Future<Directory> _directory() async {
    final folder =
        directory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/ipsc-training',
        );
    await folder.create(recursive: true);
    return folder;
  }

  Future<AppData> _read(File file) async {
    if (await file.length() > _maxBytes) {
      throw const FormatException('Data exceeds 5 MB');
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Invalid data document');
    }
    return AppData.fromJson(raw);
  }

  Future<AppData> load() async {
    await _pending;
    final folder = await _directory();
    final file = File('${folder.path}/training.json');
    if (!await file.exists()) {
      if (await File('${folder.path}/training.backup.json').exists()) {
        throw StoreException(
          'Primary data is missing. Restore the backup explicitly.',
        );
      }
      return AppData();
    }
    try {
      return await _read(file);
    } catch (error) {
      throw StoreException(
        'Cannot load saved data: $error. Original preserved; restore backup explicitly if available.',
      );
    }
  }

  Future<void> _atomic(File target, String text) async {
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(text, flush: true);
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _pending.then((_) => action());
    _pending = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<void> save(AppData data) {
    // Encode before queuing so later UI edits cannot mutate this save's snapshot.
    late final String text;
    try {
      text = jsonEncode(data.toJson());
      if (utf8.encode(text).length > _maxBytes) {
        throw const FormatException('Data exceeds 5 MB');
      }
      AppData.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (error) {
      return Future.error(error);
    }
    return _serial(() async {
      final folder = await _directory();
      final primary = File('${folder.path}/training.json');
      final backup = File('${folder.path}/training.backup.json');
      if (await primary.exists()) {
        try {
          await _read(primary);
        } catch (error) {
          throw StoreException(
            'Saved data is invalid; refusing to overwrite it: $error',
          );
        }
        await _atomic(backup, await primary.readAsString());
      } else if (await backup.exists()) {
        throw StoreException(
          'Primary data is missing; restore backup before saving.',
        );
      }
      await _atomic(primary, text);
    });
  }

  /// Explicit recovery preserves the broken original beside the recovered file.
  Future<AppData> restoreBackup() => _serial(() async {
    final folder = await _directory();
    final backup = File('${folder.path}/training.backup.json');
    late final AppData data;
    try {
      data = await _read(backup);
    } catch (error) {
      throw StoreException('Backup cannot be restored: $error');
    }
    final primary = File('${folder.path}/training.json');
    if (await primary.exists()) {
      await primary.copy(
        '${primary.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    await _atomic(primary, jsonEncode(data.toJson()));
    return data;
  });
}
