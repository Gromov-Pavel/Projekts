import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'timers_screen.dart';
import 'timer_session.dart';
import 'training_live.dart';
import 'phone_timer_screen.dart';
import 'watch_bridge.dart';
import 'watch_screen.dart';

import 'domain.dart';
import 'store.dart';
import 'exports.dart';
import 'video_screen.dart';

void main() => runApp(const PaceApp());

class PaceApp extends StatelessWidget {
  const PaceApp({super.key, this.store});
  final TrainingStore? store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'IPSC тренировОчка',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffd65320)),
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(56, 56)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
      ),
      listTileTheme: const ListTileThemeData(minTileHeight: 64),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(56, 56)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(56, 56)),
      ),
    ),
    home: TrainingHome(store: store),
  );
}

class TrainingHome extends StatefulWidget {
  const TrainingHome({super.key, this.store});
  final TrainingStore? store;
  @override
  State<TrainingHome> createState() => _TrainingHomeState();
}

class _TrainingHomeState extends State<TrainingHome>
    with WidgetsBindingObserver {
  late final store = widget.store ?? TrainingStore();
  AppData? data;
  TimerSession? _timerSession;
  WatchBridge? _watchBridge;
  WatchBridge get watchBridge => _watchBridge ??= WatchBridge(timerSession);
  Future<bool> _timerSaveQueue = Future.value(true);
  TimerSession get timerSession => _timerSession ??= TimerSession(
    onImport: (times, source) {
      final shooterId = trainingShooterId;
      final stageId = trainingStageId;
      _timerSaveQueue = _timerSaveQueue.then((_) async {
        while (busy && mounted) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (!mounted || data == null) return false;
        if (data!.runs.any((r) => r.source == source)) return true;
        return change(
          (d) => d.runs.add(
            Run(
              id: newId(),
              times: times,
              source: source,
              shooterId: shooterId,
              stageId: stageId,
            ),
          ),
        );
      });
      return _timerSaveQueue;
    },
  )..restoreKnownTimers();
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watchBridge?.dispose();
    _timerSession?.dispose();
    super.dispose();
  }

  String? loadError;
  bool busy = false;
  int page = 0;
  final selected = <String>{};
  final collapsedDates = <String>{};
  bool resultsByStage = false;
  String? resultStage;
  String? trainingShooterId, trainingStageId;
  String? chartShooterId, chartStageId;
  DateTime? chartDay;
  bool chartMatches(Run r) =>
      (chartShooterId == null || r.shooterId == chartShooterId) &&
      (chartStageId == null || r.stageId == chartStageId) &&
      (chartDay == null ||
          DateUtils.isSameDay(r.createdAt.toLocal(), chartDay));
  String xMetric = 'Время', yMetric = 'Выстрел';
  List<Run> get calculations => data!.calculations;
  static const pages = [
    'Тренировка',
    'Проходы',
    'Матч',
    'Графики',
    'Калькулятор',
    'Видео',
    'Настройки/Данные',
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    watchBridge.attachPhoneLauncher(_openPhoneTimer);
    unawaited(watchBridge.restore());
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _watchBridge?.foreground(state == AppLifecycleState.resumed);
  }

  Future<void> _openPhoneTimer() async {
    if (!mounted ||
        data == null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      throw StateError('Откройте IPSC на телефоне');
    }
    unawaited(
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PhoneTimerScreen(
            watchBridge: watchBridge,
            onSave: (times, source) => change(
              (d) => d.runs.add(
                Run(
                  id: newId(),
                  times: times,
                  source: source,
                  shooterId: trainingShooterId,
                  stageId: trainingStageId,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String newId() => DateTime.now().microsecondsSinceEpoch.toString();
  String shooter(String? id) =>
      data!.shooters.where((s) => s.id == id).firstOrNull?.name ??
      'Не назначен';
  String stage(String? id) =>
      data!.allStages.where((s) => s.id == id).firstOrNull?.name ??
      'Тренировка';
  void message(Object text) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$text')));
    }
  }

  Future<void> load({bool restore = false}) async {
    try {
      final d = restore ? await store.restoreBackup() : await store.load();
      d.selectFirstPasses();
      if (mounted) {
        setState(() {
          data = d;
          loadError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = '$e');
    }
  }

  Future<bool> change(void Function(AppData) edit) async {
    if (busy) return false;
    setState(() => busy = true);
    try {
      final next = AppData.fromJson(data!.toJson());
      edit(next);
      next.selectFirstPasses();
      await store.save(next);
      if (mounted) setState(() => data = next);
      return true;
    } catch (e) {
      message('Не сохранено: $e');
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget button(
    String text,
    VoidCallback onPressed, {
    IconData icon = Icons.add,
  }) => FilledButton.icon(
    onPressed: busy ? null : onPressed,
    icon: Icon(icon),
    label: Text(text),
  );
  Widget section(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );
  Future<bool> confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Подтверждение'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Widget build(BuildContext context) {
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Тренировка')),
        body: Center(
          child: loadError == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Не удалось открыть данные. Исходный файл сохранён.\n$loadError',
                      ),
                      button('Повторить', () => load()),
                      OutlinedButton(
                        onPressed: () async {
                          if (await confirm(
                            'Восстановить резервную копию? Повреждённый файл будет сохранён отдельно.',
                          )) {
                            load(restore: true);
                          }
                        },
                        child: const Text('Восстановить резервную копию'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }
    final content = <Widget Function()>[
      live,
      runs,
      match,
      charts,
      calculator,
      video,
      settings,
    ][page]();
    final icons = [
      Icons.timer,
      Icons.history,
      Icons.emoji_events,
      Icons.show_chart,
      Icons.calculate,
      Icons.video_library,
      Icons.folder,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(pages[page]),
        actions: [
          if (busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: [
            if (MediaQuery.sizeOf(context).width >= 950)
              NavigationRail(
                selectedIndex: page,
                onDestinationSelected: (i) => setState(() => page = i),
                labelType: NavigationRailLabelType.all,
                destinations: List.generate(
                  pages.length,
                  (i) => NavigationRailDestination(
                    icon: Icon(icons[i]),
                    label: Text(pages[i]),
                  ),
                ),
              ),
            Expanded(child: content),
          ],
        ),
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width >= 950
          ? null
          : NavigationBar(
              selectedIndex: const {0: 0, 2: 1, 3: 2, 5: 3}[page] ?? 4,
              onDestinationSelected: (index) async {
                if (index < 4) {
                  setState(() => page = [0, 2, 3, 5][index]);
                  return;
                }
                final destination = await showModalBottomSheet<int>(
                  context: context,
                  builder: (c) => SafeArea(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final i in [1, 4, 6])
                          ListTile(
                            leading: Icon(icons[i]),
                            title: Text(pages[i]),
                            selected: page == i,
                            onTap: () => Navigator.pop(c, i),
                          ),
                      ],
                    ),
                  ),
                );
                if (destination != null && mounted) {
                  setState(() => page = destination);
                }
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.timer),
                  label: 'Трен.',
                  tooltip: 'Тренировка',
                ),
                NavigationDestination(
                  icon: Icon(Icons.emoji_events),
                  label: 'Матч',
                ),
                NavigationDestination(
                  icon: Icon(Icons.show_chart),
                  label: 'Графики',
                ),
                NavigationDestination(
                  icon: Icon(Icons.video_library),
                  label: 'Видео',
                ),
                NavigationDestination(icon: Icon(Icons.menu), label: 'Ещё'),
              ],
            ),
    );
  }

  Widget scroll(List<Widget> children) =>
      ListView(padding: const EdgeInsets.all(12), children: children);
  Widget live() {
    final history = List<Run>.of(data!.runs)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    String date(Run run) {
      final value = run.createdAt.toLocal();
      return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';
    }

    void toggle(Run run) {
      if (!selected.contains(run.id) && selected.length >= 10) {
        message('Для графика можно выбрать до 10 проходов');
        return;
      }
      setState(() {
        if (!selected.remove(run.id)) selected.add(run.id);
      });
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: ListenableBuilder(
                  listenable: timerSession,
                  builder: (context, _) {
                    final locked =
                        busy ||
                        timerSession.links.values.any((l) => l.active != null);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          key: ValueKey('training-shooter:$trainingShooterId'),
                          initialValue: trainingShooterId ?? '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Стрелок для новых проходов',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('Не выбран'),
                            ),
                            ...data!.shooters.map(
                              (s) => DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: locked
                              ? null
                              : (v) => setState(
                                  () => trainingShooterId = v == '' ? null : v,
                                ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey('training-stage:$trainingStageId'),
                          initialValue:
                              data!.stages.any((s) => s.id == trainingStageId)
                              ? trainingStageId
                              : '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Упражнение для новых проходов',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('Без упражнения'),
                            ),
                            ...data!.stages.map(
                              (s) => DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                          onChanged: locked
                              ? null
                              : (v) => setState(
                                  () => trainingStageId = v == '' ? null : v,
                                ),
                        ),
                        if (locked)
                          const Text('Выбор зафиксирован до завершения серии.'),
                      ],
                    );
                  },
                ),
              ),
              TrainingLive(session: timerSession, latest: history.firstOrNull),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TimersScreen(session: timerSession),
                        ),
                      ),
                      icon: const Icon(Icons.bluetooth),
                      label: const Text('Внешний таймер'),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _openPhoneTimer,
                          icon: const Icon(Icons.mic),
                          label: const Text('Таймер телефона'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => editRun(),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Ввести проход'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'История серий',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (selected.isNotEmpty)
                      IconButton(
                        tooltip: 'Снять выбор',
                        onPressed: () => setState(selected.clear),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: selected.isEmpty
                    ? const Text(
                        'Удерживайте проход для выбора и сравнения на графике.',
                      )
                    : FilledButton.icon(
                        onPressed: () => setState(() => page = 3),
                        icon: const Icon(Icons.show_chart),
                        label: Text(
                          'Сравнить на графике · ${selected.length}/10',
                        ),
                      ),
              ),
              if (history.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Серий пока нет. Завершённые серии внешнего таймера появятся здесь автоматически.',
                  ),
                ),
            ],
          ),
        ),
        SliverList.builder(
          itemCount: history.length,
          itemBuilder: (context, index) {
            final run = history[index];
            final time = run.createdAt.toLocal();
            final checked = selected.contains(run.id);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (index == 0 || date(history[index - 1]) != date(run))
                  Container(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(date(run))),
                        IconButton(
                          tooltip: collapsedDates.contains(date(run))
                              ? 'Развернуть'
                              : 'Свернуть',
                          icon: Icon(
                            collapsedDates.contains(date(run))
                                ? Icons.expand_more
                                : Icons.expand_less,
                          ),
                          onPressed: () => setState(() {
                            if (!collapsedDates.remove(date(run))) {
                              collapsedDates.add(date(run));
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
                if (!collapsedDates.contains(date(run)))
                  ListTile(
                    selected: checked,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: selected.isEmpty
                        ? null
                        : Checkbox(
                            value: checked,
                            onChanged: (_) => toggle(run),
                          ),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          shooter(run.shooterId),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${run.totalTime.toStringAsFixed(2)} с',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                            Text(
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '${stage(run.stageId)} · ${run.times.length} выстрелов\nПоследний сплит: ${run.splits.isEmpty ? '—' : '${run.splits.last.toStringAsFixed(2)} с'}',
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Добавить в матч / результат',
                      icon: const Icon(Icons.playlist_add),
                      onPressed: () => editRun(existing: run),
                    ),
                    onLongPress: () => toggle(run),
                    onTap: () => selected.isNotEmpty
                        ? toggle(run)
                        : editRun(existing: run),
                  ),
                if (!collapsedDates.contains(date(run)))
                  const Divider(height: 1),
              ],
            );
          },
        ),
        SliverToBoxAdapter(
          child: TextButton.icon(
            onPressed: importCsv,
            icon: const Icon(Icons.upload_file),
            label: const Text('Импорт PractiScore CSV'),
          ),
        ),
      ],
    );
  }

  Widget runs() => scroll([
    Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        button('Новый проход', () => editRun()),
        OutlinedButton(onPressed: importCsv, child: const Text('Импорт CSV')),
      ],
    ),
    const SizedBox(height: 12),
    if (data!.runs.isEmpty)
      const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Проходов пока нет. Введите результат или импортируйте PractiScore Log.',
        ),
      ),
    ...data!.runs.reversed.map(
      (r) => Card(
        child: ListTile(
          minVerticalPadding: 16,
          title: Text(
            '${shooter(r.shooterId)} · ${r.totalTime.toStringAsFixed(2)} с',
            style: const TextStyle(fontSize: 20),
          ),
          subtitle: Text(
            '${stage(r.stageId)} · ${r.times.length} выстрелов · HF ${r.hitFactor.toStringAsFixed(4)}\n${r.source}${r.selected ? ' · ЗАЧЁТ' : ''}',
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => editRun(existing: r),
        ),
      ),
    ),
  ]);
  Future<void> chooseScoringPasses() async {
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, refresh) => AlertDialog(
          title: const Text('Зачётные проходы'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final person in data!.shooters)
                    for (final exercise in data!.stages)
                      if (data!.matchRuns.any(
                        (r) =>
                            r.shooterId == person.id &&
                            r.stageId == exercise.id,
                      ))
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${person.name} · ${exercise.name}',
                              style: Theme.of(c).textTheme.titleMedium,
                            ),
                            for (final r in data!.matchRuns.where(
                              (r) =>
                                  r.shooterId == person.id &&
                                  r.stageId == exercise.id,
                            ))
                              ListTile(
                                leading: Icon(
                                  r.selected
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                ),
                                title: Text(
                                  '${r.totalTime.toStringAsFixed(2)} с · ${r.score} очков · HF ${r.hitFactor.toStringAsFixed(4)}',
                                ),
                                subtitle: Text(
                                  r.createdAt
                                      .toLocal()
                                      .toString()
                                      .split('.')
                                      .first,
                                ),
                                onTap: busy
                                    ? null
                                    : () async {
                                        await change((d) {
                                          for (
                                            var i = 0;
                                            i < d.runs.length;
                                            i++
                                          ) {
                                            final old = d.runs[i];
                                            if (old.shooterId == person.id &&
                                                old.stageId == exercise.id) {
                                              d.revisions.add({
                                                'at': DateTime.now()
                                                    .toIso8601String(),
                                                'reason':
                                                    'Выбор зачётного прохода',
                                                'run': old.toJson(),
                                              });
                                              d.runs[i] = old.copyWith(
                                                selected: old.id == r.id,
                                              );
                                            }
                                          }
                                        });
                                        if (c.mounted) refresh(() {});
                                      },
                              ),
                          ],
                        ),
                  if (data!.matchRuns.isEmpty)
                    const Text(
                      'Добавьте проход: выберите стрелка и упражнение на экране Тренировка.',
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> exportMatch() async {
    final format = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Экспорт матча'),
        children: [
          for (final f in ['xlsx', 'pdf', 'json'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, f),
              child: Text(f.toUpperCase()),
            ),
        ],
      ),
    );
    if (format == null) return;
    try {
      await exportTraining(
        AppData(
          shooters: data!.shooters,
          stages: data!.stages,
          runs: data!.matchRuns,
        ),
        format,
        match: true,
      );
    } catch (e) {
      message('Ошибка экспорта: $e');
    }
  }

  Future<void> newMatch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Новый матч?'),
        content: const Text(
          'Текущие упражнения уйдут в архив данных. Проходы и участники сохранятся. Для нового матча добавьте упражнения заново. Старый матч можно сохранить кнопкой «Экспорт матча».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Создать матч'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final saved = await change((d) => d.newMatch());
      if (saved && mounted) {
        setState(() {
          resultStage = null;
          trainingStageId = null;
        });
      }
    }
  }

  Future<void> showArchives() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => Scaffold(
          appBar: AppBar(title: const Text('Архив матчей')),
          body: data!.archivedMatches.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Здесь появятся завершённые матчи после нажатия «Новый матч».',
                    ),
                  ),
                )
              : ListView(
                  children: [
                    for (final match in data!.archivedMatches.reversed)
                      ListTile(
                        title: Text(
                          match.createdAt.millisecondsSinceEpoch == 0
                              ? 'Ранее сохранённый архив'
                              : 'Матч · ${match.createdAt.toLocal().toString().split('.').first}',
                        ),
                        subtitle: Text('${match.stageIds.length} упражнений'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => openArchive(match),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> openArchive(MatchArchive archive) async {
    final snapshot = AppData.fromJson(data!.toJson());
    final stages = snapshot.archivedStages
        .where((s) => archive.stageIds.contains(s.id))
        .toList();
    final runs = snapshot.runs
        .where((r) => archive.stageIds.contains(r.stageId))
        .toList();
    String? stageId;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => StatefulBuilder(
          builder: (c, refresh) {
            final shownStages = stageId == null
                ? stages
                : stages.where((s) => s.id == stageId).toList();
            final shownRuns = runs
                .where((r) => shownStages.any((s) => s.id == r.stageId))
                .toList();
            final totals = matchTotals(shownStages, shownRuns);
            final people =
                snapshot.shooters
                    .where((s) => runs.any((r) => r.shooterId == s.id))
                    .toList()
                  ..sort(
                    (a, b) => (totals[b.id] ?? 0).compareTo(totals[a.id] ?? 0),
                  );
            final best = totals.values.fold<double>(0, (a, b) => a > b ? a : b);
            return Scaffold(
              appBar: AppBar(title: const Text('Результаты архива')),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Завершённый матч · только просмотр'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Матч / упражнение',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Матч целиком'),
                      ),
                      ...stages.map(
                        (s) => DropdownMenuItem(
                          value: s.id,
                          child: Text(s.name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                    onChanged: (v) =>
                        refresh(() => stageId = v == '' ? null : v),
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < people.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${i + 1}. ${people[i].name}',
                            style: Theme.of(c).textTheme.titleMedium,
                          ),
                          Text(
                            '${(totals[people[i].id] ?? 0).toStringAsFixed(4)} очк. · ${(best > 0 ? (totals[people[i].id] ?? 0) / best * 100 : 0).toStringAsFixed(2)} %',
                          ),
                        ],
                      ),
                    ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Экспорт архива XLSX'),
                    onPressed: () async {
                      try {
                        await exportTraining(
                          AppData(
                            shooters: snapshot.shooters,
                            stages: stages,
                            runs: runs,
                          ),
                          'xlsx',
                          match: true,
                        );
                      } catch (e) {
                        message('Ошибка экспорта: $e');
                      }
                    },
                  ),
                  const Divider(),
                  for (final stage in stages)
                    ExpansionTile(
                      title: Text(stage.name),
                      children: [
                        for (final r in runs.where(
                          (r) => r.stageId == stage.id,
                        ))
                          ListTile(
                            title: Text(
                              '${snapshot.shooters.where((s) => s.id == r.shooterId).firstOrNull?.name ?? 'Не назначен'} · ${r.totalTime.toStringAsFixed(2)} с',
                            ),
                            subtitle: Text(
                              '${r.score} очков · HF ${r.hitFactor.toStringAsFixed(4)}${r.selected ? ' · Зачёт' : ''}',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget match() {
    final stageId = data!.stages.any((s) => s.id == resultStage)
        ? resultStage
        : data!.stages.firstOrNull?.id;
    final stages = resultsByStage
        ? data!.stages.where((s) => s.id == stageId).toList()
        : data!.stages;
    final runs = data!.matchRuns
        .where((r) => stages.any((s) => s.id == r.stageId))
        .toList();
    final totals = matchTotals(stages, runs);
    final ranking = [...data!.shooters]
      ..sort((a, b) => (totals[b.id] ?? 0).compareTo(totals[a.id] ?? 0));
    final best = totals.values.fold<double>(0, (a, b) => a > b ? a : b);
    return scroll([
      section('Упражнения', [
        button('Добавить упражнение', editStage),
        ...data!.stages.map(
          (s) => ListTile(
            title: Text(s.name),
            subtitle: Text(
              '${s.paper} бумага · ${s.steel} сталь · NS ${s.noShoots} · максимум ${s.maxPoints}',
            ),
            onTap: () => editStage(existing: s),
          ),
        ),
      ]),
      section('Участники', [
        button('Добавить стрелка', editShooter),
        ...data!.shooters.map(
          (s) => ListTile(
            title: Text(s.name),
            trailing: const Icon(Icons.edit),
            onTap: () => editShooter(existing: s),
          ),
        ),
      ]),
      section('Результаты', [
        LayoutBuilder(
          builder: (context, constraints) => SegmentedButton<bool>(
            direction:
                constraints.maxWidth < 340 ||
                    MediaQuery.textScalerOf(context).scale(1) > 1.3
                ? Axis.vertical
                : Axis.horizontal,
            segments: const [
              ButtonSegment(value: false, label: Text('Матч')),
              ButtonSegment(value: true, label: Text('Упражнения')),
            ],
            selected: {resultsByStage},
            onSelectionChanged: (v) => setState(() => resultsByStage = v.first),
          ),
        ),
        if (resultsByStage && data!.stages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: DropdownButtonFormField<String>(
              key: ValueKey(stageId),
              initialValue: stageId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Упражнение'),
              items: data!.stages
                  .map(
                    (s) => DropdownMenuItem(
                      value: s.id,
                      child: Text(s.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => resultStage = v),
            ),
          ),
        if (runs.isNotEmpty && !runs.any((r) => r.selected && r.hitFactor > 0))
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Для расчёта укажите время и попадания в зачётных проходах.',
            ),
          ),
        if (runs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Назначьте проходу стрелка и упражнение на экране Тренировка.',
            ),
          ),
        ...ranking.asMap().entries.map((e) {
          final points = totals[e.value.id] ?? 0;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    '${e.key + 1}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.value.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          Text(
                            '${points.toStringAsFixed(4)} очк.',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                          Text(
                            '${(best > 0 ? points / best * 100 : 0).toStringAsFixed(2)} %',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
        OutlinedButton(
          onPressed: chooseScoringPasses,
          child: const Text('Зачётные проходы'),
        ),
      ]),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            onPressed: showArchives,
            icon: const Icon(Icons.history),
            label: const Text('Архив матчей'),
          ),
          OutlinedButton.icon(
            onPressed: exportMatch,
            icon: const Icon(Icons.ios_share),
            label: const Text('Экспорт матча'),
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : newMatch,
            icon: const Icon(Icons.add),
            label: const Text('Новый матч'),
          ),
        ],
      ),
    ]);
  }

  List<double> metric(Run run, String key) => key == 'Выстрел'
      ? List.generate(run.times.length, (i) => (i + 1).toDouble())
      : key == 'Время'
      ? run.times
      : run.splits;
  String metricLabel(String key) => key == 'Выстрел'
      ? 'Номер выстрела'
      : key == 'Время'
      ? 'Время от старта, с'
      : 'Сплит, с';
  Widget axisTick(double value, TitleMeta meta, String key) {
    if (key == 'Выстрел' && (value - value.round()).abs() > .001) {
      return const SizedBox.shrink();
    }
    return SideTitleWidget(
      meta: meta,
      child: Text(
        key == 'Выстрел' ? '${value.round()}' : value.toStringAsFixed(1),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget graphPlot(List<Run> chartRuns, List<Color> colors) => LineChart(
    LineChartData(
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          fitInsideHorizontally: true,
          fitInsideVertically: true,
          getTooltipItems: (spots) => spots
              .map(
                (spot) => LineTooltipItem(
                  '${shooter(chartRuns[spot.barIndex].shooterId)}\nВремя ${chartRuns[spot.barIndex].times[spot.spotIndex].toStringAsFixed(2)} с\nСплит ${chartRuns[spot.barIndex].splits[spot.spotIndex].toStringAsFixed(2)} с\n№${spot.spotIndex + 1}',
                  const TextStyle(color: Colors.white, fontSize: 13),
                ),
              )
              .toList(),
        ),
      ),
      lineBarsData: chartRuns.asMap().entries.map((e) {
        final xs = metric(e.value, xMetric), ys = metric(e.value, yMetric);
        return LineChartBarData(
          spots: List.generate(xs.length, (i) => FlSpot(xs[i], ys[i])),
          color: colors[e.key],
          barWidth: 3,
          isCurved: false,
          dashArray: e.key >= 5 ? [8, 4] : null,
        );
      }).toList(),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        bottomTitles: AxisTitles(
          axisNameWidget: Text(metricLabel(xMetric)),
          axisNameSize: 28,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 32,
            getTitlesWidget: (value, meta) => axisTick(value, meta, xMetric),
          ),
        ),
        leftTitles: AxisTitles(
          axisNameWidget: Text(metricLabel(yMetric)),
          axisNameSize: 24,
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 44,
            getTitlesWidget: (value, meta) => axisTick(value, meta, yMetric),
          ),
        ),
      ),
      minX: 0,
      minY: 0,
    ),
  );
  Future<void> chartSettings() async {
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, refresh) => AlertDialog(
          title: const Text('Настройки графика'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 24,
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final isX in [true, false])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: isX ? xMetric : yMetric,
                        decoration: InputDecoration(
                          labelText: isX ? 'Ось X' : 'Ось Y',
                        ),
                        items: ['Выстрел', 'Время', 'Сплит']
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(
                                  metricLabel(v),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => refresh(() {
                          if (isX) {
                            xMetric = v!;
                          } else {
                            yMetric = v!;
                          }
                        }),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget charts() {
    final chartRuns = data!.runs
        .where(
          (r) =>
              selected.contains(r.id) && r.times.isNotEmpty && chartMatches(r),
        )
        .toList();
    final colors = [
      Colors.deepOrange,
      Colors.blue,
      Colors.green,
      Colors.purple,
      Colors.brown,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.lime.shade900,
      Colors.blueGrey,
    ];
    return scroll([
      section('Фильтры', [
        DropdownButtonFormField<String>(
          key: ValueKey('chart-shooter:$chartShooterId'),
          initialValue: chartShooterId ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Стрелок'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Все стрелки')),
            ...data!.shooters.map(
              (s) => DropdownMenuItem(
                value: s.id,
                child: Text(s.name, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: (v) => setState(() => chartShooterId = v == '' ? null : v),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('chart-stage:$chartStageId'),
          initialValue: chartStageId ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Упражнение'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Все упражнения')),
            ...data!.allStages.map(
              (s) => DropdownMenuItem(
                value: s.id,
                child: Text(s.name, overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: (v) => setState(() => chartStageId = v == '' ? null : v),
        ),
        Wrap(
          spacing: 12,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.calendar_today),
              label: Text(
                chartDay == null
                    ? 'Все даты'
                    : '${chartDay!.day}.${chartDay!.month}.${chartDay!.year}',
              ),
              onPressed: () async {
                final dates =
                    data!.runs.map((r) => r.createdAt.toLocal()).toList()
                      ..sort();
                final date = await showDatePicker(
                  context: context,
                  initialDate: chartDay ?? dates.lastOrNull ?? DateTime.now(),
                  firstDate: dates.firstOrNull ?? DateTime.now(),
                  lastDate: dates.lastOrNull ?? DateTime.now(),
                );
                if (date != null && mounted) setState(() => chartDay = date);
              },
            ),
            TextButton(
              onPressed: () => setState(() {
                chartDay = null;
                chartShooterId = null;
                chartStageId = null;
              }),
              child: const Text('Сбросить фильтры'),
            ),
          ],
        ),
        const Text('Фильтры скрывают линии и проходы, сохраняя ваш выбор.'),
      ]),
      section('Сравнение проходов · ${selected.length}/10', [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Настройки графика',
            icon: const Icon(Icons.settings),
            onPressed: chartSettings,
          ),
        ),
        Text('X: ${metricLabel(xMetric)} · Y: ${metricLabel(yMetric)}'),
        const SizedBox(height: 16),
        if (chartRuns.isEmpty)
          const Text('Выберите проходы с временами отдельных выстрелов ниже.')
        else
          SizedBox(height: 300, child: graphPlot(chartRuns, colors)),
        if (chartRuns.isNotEmpty)
          OutlinedButton.icon(
            icon: const Icon(Icons.fullscreen),
            label: const Text('График на весь экран'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => Scaffold(
                  appBar: AppBar(
                    title: Text('Сравнение ${chartRuns.length} проходов'),
                  ),
                  body: SafeArea(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'X: ${metricLabel(xMetric)} · Y: ${metricLabel(yMetric)}',
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 20, 12),
                            child: graphPlot(chartRuns, colors),
                          ),
                        ),
                        SizedBox(
                          height: 80,
                          child: ListView(
                            children: [
                              for (var i = 0; i < chartRuns.length; i++)
                                ListTile(
                                  dense: true,
                                  leading: Icon(
                                    Icons.horizontal_rule,
                                    color: colors[i],
                                  ),
                                  title: Text(
                                    '${shooter(chartRuns[i].shooterId)} · ${chartRuns[i].totalTime.toStringAsFixed(2)} с',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ...chartRuns.asMap().entries.map(
          (e) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  e.key >= 5 ? Icons.more_horiz : Icons.horizontal_rule,
                  color: colors[e.key],
                ),
                Expanded(
                  child: Text(
                    '${shooter(e.value.shooterId)} · ${stage(e.value.stageId)} · ${e.value.totalTime.toStringAsFixed(2)} с · ${e.value.createdAt.toLocal().toString().split('.').first}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
      section('Выбрать проходы', [
        ...data!.runs.reversed
            .where((r) => r.times.isNotEmpty && chartMatches(r))
            .map(
              (r) => CheckboxListTile(
                value: selected.contains(r.id),
                onChanged: !selected.contains(r.id) && selected.length >= 10
                    ? null
                    : (v) => setState(() {
                        if (v == true) {
                          selected.add(r.id);
                        } else {
                          selected.remove(r.id);
                        }
                      }),
                title: Text(
                  '${shooter(r.shooterId)} · ${r.totalTime.toStringAsFixed(2)} с',
                ),
                subtitle: Text(
                  '${stage(r.stageId)} · ${r.createdAt.toLocal().toString().split('.').first}',
                ),
              ),
            ),
      ]),
      if (chartRuns.isNotEmpty)
        section('Таблица выстрелов', [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Проход')),
                DataColumn(label: Text('Выстрел')),
                DataColumn(label: Text('От старта, с')),
                DataColumn(label: Text('Сплит, с')),
              ],
              rows: [
                for (final r in chartRuns)
                  for (var i = 0; i < r.times.length; i++)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(
                            '${shooter(r.shooterId)} / ${r.totalTime.toStringAsFixed(2)}',
                          ),
                        ),
                        DataCell(Text('${i + 1}')),
                        DataCell(Text(r.times[i].toStringAsFixed(2))),
                        DataCell(Text(r.splits[i].toStringAsFixed(2))),
                      ],
                    ),
              ],
            ),
          ),
        ]),
    ]);
  }

  Widget calculator() {
    final base = calculations.firstOrNull?.hitFactor ?? 0;
    return scroll([
      section('Что, если…', [
        const Text(
          'До пяти независимых вариантов. Изменения не затрагивают исходные проходы.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            button('Добавить вариант', () {
              if (calculations.length >= 5) {
                message('Максимум пять вариантов');
                return;
              }
              editRun(calcIndex: calculations.length);
            }),
            OutlinedButton(
              onPressed: () async {
                final run = await chooseRun();
                if (run != null && mounted) {
                  if (calculations.length >= 5) {
                    message('Максимум пять вариантов');
                    return;
                  }
                  await change(
                    (d) => d.calculations.add(
                      Run.fromJson({
                        ...run.toJson(),
                        'id': newId(),
                        'shooterId': null,
                        'stageId': null,
                        'selected': false,
                      }),
                    ),
                  );
                }
              },
              child: const Text('Из сохранённого прохода'),
            ),
          ],
        ),
      ]),
      ...calculations.asMap().entries.map(
        (e) => section('Вариант ${e.key + 1}', [
          Text(
            'HF ${e.value.hitFactor.toStringAsFixed(4)}',
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
          Text(
            '${e.value.score} очков / ${e.value.totalTime.toStringAsFixed(2)} с · ${e.value.major ? 'Major' : 'Minor'}',
          ),
          Text(
            'Разница HF ${(e.value.hitFactor - base).toStringAsFixed(4)}${base > 0 ? ' / ${((e.value.hitFactor / base - 1) * 100).toStringAsFixed(2)}%' : ''}',
          ),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: () => editRun(existing: e.value, calcIndex: e.key),
                child: const Text('Изменить'),
              ),
              if (calculations.length > 1)
                TextButton(
                  onPressed: () =>
                      change((d) => d.calculations.removeAt(e.key)),
                  child: const Text('Убрать'),
                ),
            ],
          ),
        ]),
      ),
    ]);
  }

  Future<Run?> chooseRun() => showDialog<Run>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('Выбрать проход'),
      children: data!.runs.reversed
          .map(
            (r) => SimpleDialogOption(
              onPressed: () => Navigator.pop(c, r),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${shooter(r.shooterId)} · ${r.totalTime.toStringAsFixed(2)} с · ${stage(r.stageId)}',
                ),
              ),
            ),
          )
          .toList(),
    ),
  );
  Widget video() => VideoScreen(runs: data!.runs, shooters: data!.shooters);
  Widget settings() => scroll([
    section('Настройки', [
      OutlinedButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TimersScreen(session: timerSession),
          ),
        ),
        child: const Text('Подключить таймер'),
      ),
      OutlinedButton.icon(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => WatchScreen(bridge: watchBridge)),
        ),
        icon: const Icon(Icons.watch),
        label: const Text('Подключить часы'),
      ),
    ]),
    section('Локальные данные', [
      Text(
        '${data!.shooters.length} стрелков · ${data!.stages.length} упражнений · ${data!.runs.length} проходов\nИстория исправлений: ${data!.revisions.length}',
      ),
      const SizedBox(height: 16),
      button('Импорт PractiScore CSV', importCsv, icon: Icons.upload_file),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final format in ['json', 'xlsx', 'pdf'])
            OutlinedButton(
              onPressed: () async {
                try {
                  await exportTraining(data!, format);
                } catch (e) {
                  message('Ошибка экспорта: $e');
                }
              },
              child: Text('Экспорт ${format.toUpperCase()}'),
            ),
          OutlinedButton(
            onPressed: importJson,
            child: const Text('Восстановить JSON'),
          ),
        ],
      ),
    ]),
    section('Сохранность', [
      const Text(
        'Данные хранятся на этом устройстве. Экспортируйте JSON перед удалением приложения. JSON пока содержит результаты и историю, без видео. XLSX/PDF содержат таблицу проходов. Сетевой обмен, права тренера, публичный экран и пакет с медиа ещё в разработке.',
      ),
    ]),
    section('Версия разработки', [
      const Text(
        'Android · IPSC тренировОчка 0.3.1\nТаймеры BLE, фон, микрофонный таймер и рендеринг видео пока не квалифицированы. Ручной ввод и импорт не заменяют аппаратную проверку.',
      ),
    ]),
  ]);
  Future<void> importCsv() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (picked.isEmpty) return;
      final f = picked.single;
      if ((await f.length() ?? 5 * 1024 * 1024 + 1) > 5 * 1024 * 1024) {
        throw const FormatException('CSV больше 5 МБ');
      }
      final text = utf8.decode(await f.readAsBytes());
      final imported = importPractiScoreCsv(text);
      var added = 0;
      final saved = await change((d) {
        final mapping = <String, String>{};
        for (final s in imported.shooters) {
          final existing = d.shooters
              .where((e) => e.id == s.id || e.name == s.name)
              .firstOrNull;
          mapping[s.id] = existing?.id ?? s.id;
          if (existing == null) d.shooters.add(s);
        }
        for (final r in imported.runs) {
          if (!d.runs.any((e) => e.id == r.id)) {
            d.runs.add(r.copyWith(shooterId: mapping[r.shooterId]));
            added++;
          }
        }
      });
      if (!saved) return;
      message(
        'Новых проходов: $added. Попадания и упражнения не импортируются из таймерного лога.',
      );
    } catch (e) {
      message('Импорт не выполнен: $e');
    }
  }

  Future<void> importJson() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (picked.isEmpty) return;
      final f = picked.single;
      if ((await f.length() ?? 5 * 1024 * 1024 + 1) > 5 * 1024 * 1024) {
        throw const FormatException('Файл больше 5 МБ');
      }
      final incoming = AppData.fromJson(
        jsonDecode(utf8.decode(await f.readAsBytes())) as Map<String, dynamic>,
      );
      if (!await confirm(
        'Заменить текущие данные: ${incoming.runs.length} проходов? Сначала экспортируйте текущую тренировку.',
      )) {
        return;
      }
      final saved = await change((d) {
        d.shooters
          ..clear()
          ..addAll(incoming.shooters);
        d.stages
          ..clear()
          ..addAll(incoming.stages);
        d.archivedStages
          ..clear()
          ..addAll(incoming.archivedStages);
        d.archivedMatches
          ..clear()
          ..addAll(incoming.archivedMatches);
        d.runs
          ..clear()
          ..addAll(incoming.runs);
        d.calculations
          ..clear()
          ..addAll(incoming.calculations);
        d.revisions
          ..clear()
          ..addAll(incoming.revisions);
      });
      if (saved && mounted) {
        setState(() {
          selected.clear();
          trainingShooterId = null;
          trainingStageId = null;
          chartShooterId = null;
          chartStageId = null;
          chartDay = null;
          resultStage = null;
        });
      }
    } catch (e) {
      message('Импорт не выполнен: $e');
    }
  }

  Future<void> editShooter({Shooter? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Стрелок'),
        content: TextField(
          controller: name,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Имя'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(c, true);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await change((d) {
        final s = Shooter(id: existing?.id ?? newId(), name: name.text.trim());
        final i = d.shooters.indexWhere((v) => v.id == s.id);
        if (i < 0) {
          d.shooters.add(s);
        } else {
          d.shooters[i] = s;
        }
      });
    }
    name.dispose();
  }

  Future<void> editStage({Stage? existing}) async {
    final labels = [
      'Название',
      'Бумажные мишени',
      'Стальные мишени',
      'No-shoot',
      'Попаданий / бумага',
      'Попаданий / сталь',
    ];
    final values = [
      existing?.name ?? '',
      '${existing?.paper ?? 0}',
      '${existing?.steel ?? 0}',
      '${existing?.noShoots ?? 0}',
      '${existing?.hitsPerPaper ?? 2}',
      '${existing?.hitsPerSteel ?? 1}',
    ];
    final fields = values.map((v) => TextEditingController(text: v)).toList();
    String? error;
    final result = await showDialog<Stage>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Упражнение'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < fields.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: fields[i],
                        keyboardType: i == 0
                            ? TextInputType.text
                            : TextInputType.number,
                        decoration: InputDecoration(labelText: labels[i]),
                      ),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(c).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final nums = fields
                      .skip(1)
                      .map((f) => int.parse(f.text))
                      .toList();
                  final s = Stage(
                    id: existing?.id ?? newId(),
                    name: fields[0].text.trim(),
                    paper: nums[0],
                    steel: nums[1],
                    noShoots: nums[2],
                    hitsPerPaper: nums[3],
                    hitsPerSteel: nums[4],
                  );
                  if (s.maxPoints <= 0) {
                    throw const FormatException(
                      'Добавьте хотя бы одну зачётную мишень',
                    );
                  }
                  Navigator.pop(c, s);
                } catch (e) {
                  set(
                    () => error = 'Проверьте название и целые неотрицательные количества.',
                  );
                }
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await change((d) {
        final i = d.stages.indexWhere((s) => s.id == result.id);
        if (i < 0) {
          d.stages.add(result);
        } else {
          d.stages[i] = result;
        }
      });
    }
    for (final f in fields) {
      f.dispose();
    }
  }

  Future<void> editRun({Run? existing, int? calcIndex}) async {
    final base =
        existing ??
        Run(
          id: newId(),
          shooterId: calcIndex == null ? trainingShooterId : null,
          stageId: calcIndex == null ? trainingStageId : null,
        );
    String? sid = base.shooterId, tid = base.stageId;
    var major = base.major;
    String? error;
    final labels = [
      'Общее время, с',
      'A',
      'C',
      'D',
      'Miss',
      'No-shoot',
      'Процедуры',
      'Времена от старта через пробел, с',
    ];
    final values = [
      base.totalTime > 0 ? base.totalTime.toStringAsFixed(2) : '',
      '${base.alpha}',
      '${base.charlie}',
      '${base.delta}',
      '${base.miss}',
      '${base.noShoot}',
      '${base.procedural}',
      base.times.map((t) => t.toStringAsFixed(2)).join(' '),
    ];
    final fields = values.map((v) => TextEditingController(text: v)).toList();
    final route = DialogRoute<Run>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 24,
          ),
          contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          title: Text(
            calcIndex == null ? 'Результат прохода' : 'Вариант калькулятора',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (calcIndex == null) ...[
                    DropdownButtonFormField<String>(
                      initialValue: sid ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Стрелок'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Назначить позже'),
                        ),
                        ...data!.shooters.map(
                          (s) => DropdownMenuItem(
                            value: s.id,
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (v) => sid = v == '' ? null : v,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: tid ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Упражнение',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text(
                            'Тренировка / назначить позже',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ...data!.allStages
                            .where(
                              (s) =>
                                  data!.stages.contains(s) ||
                                  s.id == base.stageId,
                            )
                            .map(
                              (s) => DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                      ],
                      onChanged: (v) => set(() => tid = v == '' ? null : v),
                    ),
                    const SizedBox(height: 12),
                  ],
                  SwitchListTile(
                    title: Text(major ? 'Major · 5/4/2' : 'Minor · 5/3/1'),
                    value: major,
                    onChanged: (v) => set(() => major = v),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: fields[0],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(labelText: labels[0]),
                    ),
                  ),
                  for (var i = 1; i <= 6; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            labels[i],
                            style: Theme.of(c).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Уменьшить ${labels[i]}',
                                onPressed: () => set(() {
                                  final n = int.tryParse(fields[i].text) ?? 0;
                                  fields[i].text = '${n > 0 ? n - 1 : 0}';
                                }),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Semantics(
                                  label: labels[i],
                                  child: TextField(
                                    key: ValueKey('run-count-$i'),
                                    controller: fields[i],
                                    textAlign: TextAlign.center,
                                    keyboardType: TextInputType.number,
                                    style: Theme.of(c).textTheme.titleLarge,
                                    decoration: const InputDecoration(
                                      hintText: '0',
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Добавить ${labels[i]}',
                                onPressed: () => set(
                                  () => fields[i].text =
                                      '${(int.tryParse(fields[i].text) ?? 0) + 1}',
                                ),
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ExpansionTile(
                    title: const Text('Времена выстрелов'),
                    children: [
                      TextField(
                        controller: fields[7],
                        maxLines: 3,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(labelText: labels[7]),
                      ),
                    ],
                  ),
                  const Text(
                    'Если указаны выстрелы, итоговое время берётся по последнему. Дробная часть — через точку.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: TextStyle(color: Theme.of(c).colorScheme.error),
                      ),
                    ),
                  ),
                if (calcIndex == null)
                  OutlinedButton.icon(
                    onPressed: tid == null
                        ? null
                        : () => set(() {
                            final stage = data!.allStages
                                .where((s) => s.id == tid)
                                .firstOrNull;
                            if (stage == null) return;
                            final counts = fields.sublist(2, 5).map((f) {
                              final text = f.text.trim();
                              return text.isEmpty ? 0 : int.tryParse(text);
                            }).toList();
                            if (counts.any((n) => n == null || n < 0)) {
                              error = 'C, D и Miss должны быть целыми неотрицательными числами.';
                              return;
                            }
                            final remaining =
                                stage.maxPoints ~/ 5 -
                                counts.fold<int>(0, (sum, n) => sum + n!);
                            if (remaining < 0) {
                              error = 'C, D и Miss больше зачётных попаданий упражнения.';
                              return;
                            }
                            fields[1].text = '$remaining';
                            for (var i = 0; i < counts.length; i++) {
                              fields[i + 2].text = '${counts[i]}';
                            }
                            error = null;
                          }),
                    icon: const Icon(Icons.done_all),
                    label: const Text('Остальное — Альфы'),
                  ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('Отмена'),
                    ),
                    FilledButton(
                      onPressed: () {
                        try {
                          final counts = fields
                              .sublist(1, 7)
                              .map((f) => int.parse(f.text))
                              .toList();
                          final ts = fields[7].text.trim().isEmpty
                              ? <double>[]
                              : fields[7].text
                                    .trim()
                                    .split(RegExp(r'\s+'))
                                    .map(double.parse)
                                    .toList();
                          final total = double.tryParse(
                            fields[0].text.replaceAll(',', '.'),
                          );
                          if (ts.isEmpty &&
                              (total == null ||
                                  !total.isFinite ||
                                  total <= 0)) {
                            throw const FormatException(
                              'Укажите положительное время',
                            );
                          }
                          final r = base.copyWith(
                            shooterId: sid,
                            stageId: tid,
                            times: ts,
                            manualTime: total,
                            alpha: counts[0],
                            charlie: counts[1],
                            delta: counts[2],
                            miss: counts[3],
                            noShoot: counts[4],
                            procedural: counts[5],
                            major: major,
                            selected:
                                base.selected &&
                                sid == base.shooterId &&
                                tid == base.stageId,
                            source: calcIndex != null
                                ? 'calculator'
                                : existing == null
                                ? 'manual'
                                : '${base.source} · исправлено вручную',
                          );
                          final st = data!.stages
                              .where((s) => s.id == tid)
                              .firstOrNull;
                          if (st != null &&
                              r.alpha + r.charlie + r.delta >
                                  st.paper * st.hitsPerPaper +
                                      st.steel * st.hitsPerSteel) {
                            throw const FormatException(
                              'Попаданий больше зачётных для упражнения',
                            );
                          }
                          Navigator.pop(c, r);
                        } catch (e) {
                          set(
                            () => error = e is FormatException
                                ? (e.message.startsWith('Invalid') ||
                                          e.message.startsWith('Negative') ||
                                          e.message.startsWith('Shot times')
                                      ? 'Проверьте значения: количества должны быть целыми и неотрицательными, времена — положительными и по возрастанию.'
                                      : e.message)
                                : 'Не удалось сохранить. Проверьте время и попадания.',
                          );
                        }
                      },
                      child: const Text('Сохранить'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    if (result != null) {
      if (calcIndex != null) {
        await change((d) {
          final calc = Run.fromJson({
            ...result.toJson(),
            'shooterId': null,
            'stageId': null,
            'selected': false,
          });
          if (calcIndex < d.calculations.length) {
            d.calculations[calcIndex] = calc;
          } else {
            d.calculations.add(calc);
          }
        });
      } else {
        await change((d) {
          final i = d.runs.indexWhere((r) => r.id == result.id);
          if (i < 0) {
            d.runs.add(result);
          } else {
            d.revisions.add({
              'at': DateTime.now().toIso8601String(),
              'reason': 'Исправлено вручную',
              'run': d.runs[i].toJson(),
            });
            d.runs[i] = result;
          }
        });
      }
    }
    for (final f in fields) {
      f.dispose();
    }
  }
}
