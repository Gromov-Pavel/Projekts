import 'dart:convert';
import 'dart:io';

class SavedTimer {
  SavedTimer(
    this.id,
    this.name, {
    this.autoConnect = true,
    this.profile = 'auto',
  });
  final String id;
  String name;
  bool autoConnect;
  String profile;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'autoConnect': autoConnect,
    'profile': profile,
  };
}

class TimerPreferences {
  final timers = <String, SavedTimer>{};
  String? selectedId;

  void read(String source) {
    final data = jsonDecode(source);
    if (data is! Map || data['schema'] != 1 || data['timers'] is! List) {
      throw const FormatException('Неверный формат списка таймеров');
    }
    final loaded = <String, SavedTimer>{};
    for (final item in (data['timers'] as List).take(100)) {
      if (item is! Map ||
          item['id'] is! String ||
          item['name'] is! String ||
          (item['id'] as String).isEmpty ||
          (item['id'] as String).length > 128 ||
          (item['name'] as String).length > 256) {
        continue;
      }
      final timer = SavedTimer(
        item['id'],
        item['name'],
        autoConnect: item['autoConnect'] == true,
        profile: item['profile'] is String ? item['profile'] : 'auto',
      );
      loaded[timer.id] = timer;
    }
    timers
      ..clear()
      ..addAll(loaded);
    selectedId = timers.containsKey(data['selectedId'])
        ? data['selectedId']
        : null;
  }

  List<SavedTimer> get ordered => timers.values.toList()
    ..sort((a, b) {
      if (a.id == selectedId) return b.id == selectedId ? 0 : -1;
      if (b.id == selectedId) return 1;
      return a.name.compareTo(b.name);
    });

  String encode() => jsonEncode({
    'schema': 1,
    'selectedId': selectedId,
    'timers': timers.values.map((t) => t.toJson()).toList(),
  });

  Future<void> save(File file) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(encode(), flush: true);
    await temporary.rename(file.path);
  }
}
