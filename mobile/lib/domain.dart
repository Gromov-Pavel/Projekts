import 'dart:convert';
import 'dart:math' as math;

String _string(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid $key');
  }
  return value;
}

int _count(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

bool _bool(Map<String, dynamic> j, String key) {
  final value = j[key];
  if (value is! bool) throw FormatException('Invalid $key');
  return value;
}

String? _optionalId(Map<String, dynamic> j, String key) =>
    j[key] == null ? null : _string(j, key);

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

class Shooter {
  final String id;
  final String name;
  Shooter({required this.id, required this.name}) {
    _require(id.trim().isNotEmpty && name.trim().isNotEmpty, 'Empty shooter');
  }
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory Shooter.fromJson(Map<String, dynamic> j) =>
      Shooter(id: _string(j, 'id'), name: _string(j, 'name'));
  Shooter copyWith({String? name}) => Shooter(id: id, name: name ?? this.name);
}

class Stage {
  final String id;
  final String name;
  final int paper, steel, noShoots, hitsPerPaper, hitsPerSteel;
  Stage({
    required this.id,
    required this.name,
    this.paper = 0,
    this.steel = 0,
    this.noShoots = 0,
    this.hitsPerPaper = 2,
    this.hitsPerSteel = 1,
  }) {
    _require(id.trim().isNotEmpty && name.trim().isNotEmpty, 'Empty stage');
    _require(
      paper >= 0 &&
          steel >= 0 &&
          noShoots >= 0 &&
          hitsPerPaper > 0 &&
          hitsPerSteel > 0,
      'Invalid targets',
    );
  }
  int get maxPoints => 5 * (paper * hitsPerPaper + steel * hitsPerSteel);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'paper': paper,
    'steel': steel,
    'noShoots': noShoots,
    'hitsPerPaper': hitsPerPaper,
    'hitsPerSteel': hitsPerSteel,
  };
  factory Stage.fromJson(Map<String, dynamic> j) => Stage(
    id: _string(j, 'id'),
    name: _string(j, 'name'),
    paper: _count(j, 'paper'),
    steel: _count(j, 'steel'),
    noShoots: _count(j, 'noShoots'),
    hitsPerPaper: _count(j, 'hitsPerPaper'),
    hitsPerSteel: _count(j, 'hitsPerSteel'),
  );
  Stage copyWith({
    String? name,
    int? paper,
    int? steel,
    int? noShoots,
    int? hitsPerPaper,
    int? hitsPerSteel,
  }) => Stage(
    id: id,
    name: name ?? this.name,
    paper: paper ?? this.paper,
    steel: steel ?? this.steel,
    noShoots: noShoots ?? this.noShoots,
    hitsPerPaper: hitsPerPaper ?? this.hitsPerPaper,
    hitsPerSteel: hitsPerSteel ?? this.hitsPerSteel,
  );
}

const _unset = Object();

class Run {
  final String id;
  final String? shooterId, stageId;

  /// Cumulative shot times in seconds, measured from the start signal.
  final List<double> times;
  final double? manualTime;
  final int alpha, charlie, delta, miss, noShoot, procedural;
  final bool major, selected;
  final String source;
  final DateTime createdAt;
  Run({
    required this.id,
    this.shooterId,
    this.stageId,
    List<double> times = const [],
    this.manualTime,
    this.alpha = 0,
    this.charlie = 0,
    this.delta = 0,
    this.miss = 0,
    this.noShoot = 0,
    this.procedural = 0,
    this.major = false,
    this.selected = false,
    this.source = 'manual',
    DateTime? createdAt,
  }) : times = List.unmodifiable(times),
       createdAt = createdAt ?? DateTime.now() {
    _require(
      id.trim().isNotEmpty && source.trim().isNotEmpty,
      'Empty run identity',
    );
    _require(
      (shooterId == null || shooterId!.trim().isNotEmpty) &&
          (stageId == null || stageId!.trim().isNotEmpty),
      'Empty reference',
    );
    _require(
      [alpha, charlie, delta, miss, noShoot, procedural].every((n) => n >= 0),
      'Negative scoring count',
    );
    _require(
      manualTime == null || (manualTime!.isFinite && manualTime! > 0),
      'Invalid manual time',
    );
    double previous = 0;
    for (final time in times) {
      _require(time.isFinite && time > previous, 'Shot times must increase');
      previous = time;
    }
  }
  int get score => math.max(
    0,
    5 * alpha +
        (major ? 4 : 3) * charlie +
        (major ? 2 : 1) * delta -
        10 * (miss + noShoot + procedural),
  );
  double get totalTime => times.isNotEmpty ? times.last : manualTime ?? 0;
  double get hitFactor =>
      totalTime.isFinite && totalTime > 0 ? score / totalTime : 0;
  List<double> get splits => List.generate(
    times.length,
    (i) => times[i] - (i == 0 ? 0 : times[i - 1]),
    growable: false,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'shooterId': shooterId,
    'stageId': stageId,
    'times': times,
    'manualTime': manualTime,
    'alpha': alpha,
    'charlie': charlie,
    'delta': delta,
    'miss': miss,
    'noShoot': noShoot,
    'procedural': procedural,
    'major': major,
    'selected': selected,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
  };
  factory Run.fromJson(Map<String, dynamic> j) {
    final rawTimes = j['times'];
    _require(
      rawTimes is List && rawTimes.every((t) => t is num),
      'Invalid times',
    );
    final manual = j['manualTime'];
    _require(manual == null || manual is num, 'Invalid manualTime');
    final date = DateTime.tryParse(_string(j, 'createdAt'));
    _require(date != null, 'Invalid createdAt');
    return Run(
      id: _string(j, 'id'),
      shooterId: _optionalId(j, 'shooterId'),
      stageId: _optionalId(j, 'stageId'),
      times: (rawTimes as List).map((t) => (t as num).toDouble()).toList(),
      manualTime: (manual as num?)?.toDouble(),
      alpha: _count(j, 'alpha'),
      charlie: _count(j, 'charlie'),
      delta: _count(j, 'delta'),
      miss: _count(j, 'miss'),
      noShoot: _count(j, 'noShoot'),
      procedural: _count(j, 'procedural'),
      major: _bool(j, 'major'),
      selected: _bool(j, 'selected'),
      source: _string(j, 'source'),
      createdAt: date,
    );
  }
  Run copyWith({
    Object? shooterId = _unset,
    Object? stageId = _unset,
    List<double>? times,
    Object? manualTime = _unset,
    int? alpha,
    int? charlie,
    int? delta,
    int? miss,
    int? noShoot,
    int? procedural,
    bool? major,
    bool? selected,
    String? source,
  }) => Run(
    id: id,
    shooterId: identical(shooterId, _unset)
        ? this.shooterId
        : shooterId as String?,
    stageId: identical(stageId, _unset) ? this.stageId : stageId as String?,
    times: times ?? this.times,
    manualTime: identical(manualTime, _unset)
        ? this.manualTime
        : (manualTime as num?)?.toDouble(),
    alpha: alpha ?? this.alpha,
    charlie: charlie ?? this.charlie,
    delta: delta ?? this.delta,
    miss: miss ?? this.miss,
    noShoot: noShoot ?? this.noShoot,
    procedural: procedural ?? this.procedural,
    major: major ?? this.major,
    selected: selected ?? this.selected,
    source: source ?? this.source,
    createdAt: createdAt,
  );
}

/// Selected runs only; duplicate selections and dangling stage references fail explicitly.
Map<String, double> matchTotals(List<Stage> stages, List<Run> runs) {
  final totals = <String, double>{};
  final stageById = {for (final stage in stages) stage.id: stage};
  _require(stageById.length == stages.length, 'Duplicate stage ID');
  final selected = <String, Map<String, Run>>{};
  for (final run in runs.where((r) => r.selected)) {
    if (run.stageId == null || run.shooterId == null) continue;
    _require(stageById.containsKey(run.stageId), 'Unknown selected stage');
    final entries = selected.putIfAbsent(run.stageId!, () => {});
    _require(
      !entries.containsKey(run.shooterId),
      'Multiple selected runs for shooter/stage',
    );
    entries[run.shooterId!] = run;
  }
  for (final entry in selected.entries) {
    final best = entry.value.values.fold<double>(
      0,
      (n, r) => math.max(n, r.hitFactor),
    );
    for (final run in entry.value.values) {
      totals.update(
        run.shooterId!,
        (n) =>
            n +
            (best > 0
                ? run.hitFactor / best * stageById[entry.key]!.maxPoints
                : 0),
        ifAbsent: () => best > 0
            ? run.hitFactor / best * stageById[entry.key]!.maxPoints
            : 0,
      );
    }
  }
  return totals;
}

class ImportResult {
  final List<Shooter> shooters;
  final List<Run> runs;
  ImportResult(List<Shooter> shooters, List<Run> runs)
    : shooters = List.unmodifiable(shooters),
      runs = List.unmodifiable(runs);
}

/// Imports PractiScore timer logs. `splits` in this export contains cumulative hundredths.
/// No points or stage assignments can be inferred from a timer log.
ImportResult importPractiScoreCsv(String text) {
  final rows = _csvRows(text.startsWith('\uFEFF') ? text.substring(1) : text);
  _require(rows.isNotEmpty, 'Empty CSV');
  final header = rows.first;
  const required = [
    'id',
    'ts',
    'time',
    'first',
    'shots',
    'splits',
    'device',
    'tag',
  ];
  _require(
    required.every(header.contains) && header.toSet().length == header.length,
    'Invalid PractiScore header',
  );
  final shooters = <String, Shooter>{};
  final runs = <String, Run>{};
  for (var index = 1; index < rows.length; index++) {
    final row = rows[index];
    if (row.every((cell) => cell.trim().isEmpty)) continue;
    _require(
      row.length == header.length,
      'CSV row ${index + 1}: wrong field count',
    );
    String cell(String key) => row[header.indexOf(key)].trim();
    int integer(String value) {
      final n = int.tryParse(value);
      _require(n != null && n >= 0, 'CSV row ${index + 1}: invalid number');
      return n!;
    }

    final timestamp = DateTime.tryParse(cell('ts'));
    _require(
      timestamp != null && cell('id').isNotEmpty && cell('device').isNotEmpty,
      'CSV row ${index + 1}: invalid identity',
    );
    final cumulative = cell('splits').isEmpty
        ? <int>[]
        : cell('splits').split(',').map((s) => integer(s.trim())).toList();
    _require(
      cumulative.isNotEmpty &&
          cumulative.length == integer(cell('shots')) &&
          cumulative.first == integer(cell('first')) &&
          cumulative.last == integer(cell('time')),
      'CSV row ${index + 1}: inconsistent shot times',
    );
    var name = cell('tag');
    if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
      name = name.substring(1, name.length - 1).trim();
    }
    final shooterId = name.isEmpty
        ? null
        : 'ps-shooter:${Uri.encodeComponent(name)}';
    if (shooterId != null) {
      shooters.putIfAbsent(shooterId, () => Shooter(id: shooterId, name: name));
    }
    final id =
        'ps-run:${base64Url.encode(utf8.encode(jsonEncode([cell('id'), cell('ts'), cell('device')])))}';
    final run = Run(
      id: id,
      shooterId: shooterId,
      times: cumulative.map((n) => n / 100).toList(),
      source: 'PractiScore: ${cell('device')}',
      createdAt: timestamp,
    );
    _require(
      !runs.containsKey(id) ||
          jsonEncode(runs[id]!.toJson()) == jsonEncode(run.toJson()),
      'Conflicting duplicate PractiScore record',
    );
    runs[id] = run;
  }
  return ImportResult(shooters.values.toList(), runs.values.toList());
}

List<List<String>> _csvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var quoted = false;
  var closedQuote = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
          closedQuote = true;
        }
      } else {
        field.write(c);
      }
    } else if (c == ',' || c == '\n' || c == '\r') {
      row.add(field.toString());
      field = StringBuffer();
      closedQuote = false;
      if (c != ',') {
        rows.add(row);
        row = [];
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      }
    } else if (c == '"' && field.isEmpty && !closedQuote) {
      quoted = true;
    } else {
      _require(!closedQuote && c != '"', 'Malformed CSV quoting');
      field.write(c);
    }
  }
  _require(!quoted, 'Unterminated CSV quoted field');
  if (field.isNotEmpty || row.isNotEmpty || closedQuote) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
