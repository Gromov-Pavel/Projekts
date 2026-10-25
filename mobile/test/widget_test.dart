import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/domain.dart';
import 'package:ipsc_training/main.dart';
import 'package:ipsc_training/store.dart';
import 'package:ipsc_training/training_live.dart';

class MemoryStore extends TrainingStore {
  MemoryStore(this.data);
  AppData data;
  @override
  Future<AppData> load() async => data;
  @override
  Future<void> save(AppData next) async {
    data = AppData.fromJson(next.toJson());
  }
}

void main() {
  testWidgets('remaining Alphas uses selected stage and preserves penalties', (
    tester,
  ) async {
    final store = MemoryStore(
      AppData(
        stages: [
          Stage(id: 'st', name: 'Упражнение 12', paper: 5, steel: 2),
          Stage(id: 'other', name: 'Упражнение 6', paper: 3),
        ],
      ),
    );
    await tester.pumpWidget(PaceApp(store: store));
    await tester.pumpAndSettle();
    final entry = find.widgetWithText(OutlinedButton, 'Ввести проход');
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final fill = find.widgetWithText(OutlinedButton, 'Остальное — Альфы');
    expect(tester.widget<OutlinedButton>(fill).onPressed, isNull);

    Future<void> chooseStage(String name) async {
      final dropdown = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(DropdownButtonFormField<String>),
          )
          .last;
      await Scrollable.ensureVisible(tester.element(dropdown), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }

    Future<void> count(int index, String value) async {
      final field = find.byKey(ValueKey('run-count-$index'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, value);
    }

    String value(int index) => tester
        .widget<TextField>(find.byKey(ValueKey('run-count-$index')))
        .controller!
        .text;
    Future<void> fillAlphas() async {
      await tester.tap(fill);
      await tester.pumpAndSettle();
    }

    await chooseStage('Упражнение 12');
    await fillAlphas();
    expect(value(1), '12'); // Includes the steel targets.
    await count(2, '2');
    await count(3, '1');
    await count(4, '1');
    await count(5, '2');
    await count(6, '3');
    await fillAlphas();
    expect(value(1), '8');
    expect(value(5), '2');
    expect(value(6), '3');
    await fillAlphas();
    expect(value(1), '8'); // Repeated taps replace rather than add.
    await count(2, '10');
    await fillAlphas();
    expect(value(1), '0');
    await count(2, '13');
    await fillAlphas();
    expect(value(1), '0');
    expect(
      find.text('C, D и Miss больше зачётных попаданий упражнения.'),
      findsOneWidget,
    );
    await count(2, '-1');
    await fillAlphas();
    expect(value(1), '0');
    expect(
      find.text('C, D и Miss должны быть целыми неотрицательными числами.'),
      findsOneWidget,
    );
    await count(2, '1.5');
    await fillAlphas();
    expect(value(1), '0');
    await count(2, '');
    await count(3, '0');
    await count(4, '0');
    await fillAlphas();
    expect(value(1), '12');
    expect(value(2), '0');
    await chooseStage('Упражнение 6');
    await fillAlphas();
    expect(value(1), '6');
    final time = find.widgetWithText(TextField, 'Общее время, с');
    await Scrollable.ensureVisible(tester.element(time), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.enterText(time, '5');
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(store.data.runs.single.alpha, 6);
    expect(store.data.runs.single.stageId, 'other');
    expect(store.data.runs.single.noShoot, 2);
    expect(store.data.runs.single.procedural, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'archive viewer shows stored totals without changing active match',
    (tester) async {
      final data = AppData(
        shooters: [Shooter(id: 's', name: 'Archive shooter')],
        archivedStages: [Stage(id: 'old', name: 'Archived stage', paper: 1)],
        archivedMatches: [
          MatchArchive(
            id: 'm',
            createdAt: DateTime(2026, 10, 18),
            stageIds: ['old'],
          ),
        ],
        runs: [
          Run(
            id: 'r',
            shooterId: 's',
            stageId: 'old',
            manualTime: 2,
            alpha: 2,
            selected: true,
          ),
        ],
      );
      final store = MemoryStore(data);
      await tester.pumpWidget(PaceApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Матч'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Архив матчей'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Архив матчей'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архив матчей'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Матч · 2026-10-18 00:00:00'));
      await tester.pumpAndSettle();
      expect(find.text('Завершённый матч · только просмотр'), findsOneWidget);
      expect(find.text('10.0000 очк. · 100.00 %'), findsOneWidget);
      expect(store.data.stages, isEmpty);
      expect(store.data.runs.single.id, 'r');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow result editor keeps count controls usable with enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(PaceApp(store: MemoryStore(AppData())));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Ввести проход'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(OutlinedButton, 'Ввести проход'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ввести проход'));
      await tester.pumpAndSettle();
      final alpha = find.byKey(const ValueKey('run-count-1'));
      await tester.ensureVisible(alpha);
      await tester.pumpAndSettle();
      expect(tester.getSize(alpha).width, greaterThanOrEqualTo(64));
      await tester.tap(find.byTooltip('Добавить A'));
      await tester.pump();
      expect(tester.widget<TextField>(alpha).controller!.text, '1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow match adapts switch and wraps a long shooter name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const name = 'Тестовый стрелок с очень длинным именем и фамилией';
    await tester.pumpWidget(
      PaceApp(
        store: MemoryStore(
          AppData(
            shooters: [Shooter(id: 's', name: name)],
            stages: [
              Stage(
                id: 'st',
                name: 'Упражнение с длинным названием для проверки',
                paper: 1,
              ),
            ],
            runs: [
              Run(
                id: 'r',
                shooterId: 's',
                stageId: 'st',
                alpha: 2,
                manualTime: 2,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Матч'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(SegmentedButton<bool>),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .direction,
      Axis.vertical,
    );
    await tester.scrollUntilVisible(
      find.text('100.00 %'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('10.0000 очк.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline home displays pass and compares selected shots', (
    tester,
  ) async {
    final store = MemoryStore(
      AppData(
        shooters: [Shooter(id: 's', name: 'Тестовый стрелок')],
        runs: [
          Run(id: 'r', shooterId: 's', times: [.85, 1.12, 1.4]),
        ],
      ),
    );
    await tester.pumpWidget(PaceApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('1.40 с'), findsWidgets);
    final graph = find.text('Графики');
    await tester.ensureVisible(graph);
    await tester.tap(graph);
    await tester.pumpAndSettle();
    expect(find.text('График'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byType(CheckboxListTile),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('График'), findsOneWidget);
    expect(
      find.text('X: Время от старта, с · Y: Номер выстрела'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'range history selection opens the existing graph with those runs',
    (tester) async {
      final store = MemoryStore(
        AppData(
          runs: [
            Run(
              id: 'a',
              times: [1.0, 1.3],
              createdAt: DateTime(2026, 10, 18, 10),
            ),
            Run(
              id: 'b',
              times: [1.1, 1.5],
              createdAt: DateTime(2026, 10, 18, 11),
            ),
          ],
        ),
      );
      await tester.pumpWidget(PaceApp(store: store));
      await tester.pumpAndSettle();
      final historyRow = find.text('11:00');
      await tester.scrollUntilVisible(
        historyRow,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(historyRow);
      await tester.pumpAndSettle();
      await tester.longPress(historyRow);
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.ensureVisible(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      final compare = find.text('Сравнить на графике · 2/10');
      await tester.scrollUntilVisible(
        compare,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(compare);
      await tester.pumpAndSettle();
      expect(find.text('График'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('history dates collapse and graph axes live in settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      PaceApp(
        store: MemoryStore(
          AppData(
            runs: [
              Run(
                id: 'r',
                times: [1, 2],
                createdAt: DateTime(2026, 10, 18, 11),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byTooltip('Свернуть'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byTooltip('Свернуть'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Свернуть'));
    await tester.pumpAndSettle();
    expect(find.text('11:00'), findsNothing);
    await tester.tap(find.byTooltip('Развернуть'));
    await tester.pumpAndSettle();
    expect(find.text('11:00'), findsOneWidget);
    await tester.tap(find.text('Графики'));
    await tester.pumpAndSettle();
    expect(find.text('Ось X'), findsNothing);
    await tester.ensureVisible(find.byTooltip('Настройки графика'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Настройки графика'));
    await tester.pumpAndSettle();
    expect(find.text('Ось X'), findsOneWidget);
    expect(find.text('Ось Y'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('match shows default scoring results and grouped pass picker', (
    tester,
  ) async {
    await tester.pumpWidget(
      PaceApp(
        store: MemoryStore(
          AppData(
            shooters: [Shooter(id: 's', name: 'Shooter')],
            stages: [Stage(id: 'st', name: 'Exercise', paper: 1)],
            runs: [
              Run(
                id: 'r',
                shooterId: 's',
                stageId: 'st',
                manualTime: 2,
                alpha: 2,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Матч'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Зачётные проходы'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('100.00 %'), findsOneWidget);
    expect(find.text('10.0000 очк.'), findsOneWidget);
    await tester.ensureVisible(
      find.widgetWithText(OutlinedButton, 'Зачётные проходы'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Зачётные проходы'));
    await tester.pumpAndSettle();
    expect(find.text('Shooter · Exercise'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calculator loads saved variants', (tester) async {
    final store = MemoryStore(
      AppData(calculations: [Run(id: 'calc', manualTime: 4, alpha: 8)]),
    );
    await tester.pumpWidget(PaceApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ещё'));
    await tester.pumpAndSettle();
    final tab = find.text('Калькулятор');
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(find.text('HF 10.0000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('small Android viewport renders navigation without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PaceApp(store: MemoryStore(AppData())));
    await tester.pumpAndSettle();
    expect(find.byType(TrainingLive), findsOneWidget);
    expect(find.text('Тренировка'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'first chart selection keeps its scroll position; background restores the chosen screen',
    (tester) async {
      final store = MemoryStore(
        AppData(
          runs: [
            Run(id: 'r', times: [1, 2]),
          ],
        ),
      );
      await tester.pumpWidget(PaceApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Графики'));
      await tester.pumpAndSettle();
      final check = find.byType(CheckboxListTile);
      await tester.scrollUntilVisible(
        check,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(check).dy;
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(check).dy, closeTo(before, 1));
      expect(find.text('Таблица выстрелов'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.restartAndRestore();
      await tester.pumpAndSettle();
      expect(find.text('Графики'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byType(CheckboxListTile),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('participant removal and return affect only current match', (
    tester,
  ) async {
    final store = MemoryStore(
      AppData(
        shooters: [
          Shooter(id: 'a', name: 'Alpha'),
          Shooter(id: 'b', name: 'Bravo'),
        ],
        stages: [Stage(id: 'st', name: 'Stage')],
        runs: [
          Run(id: 'r', shooterId: 'a', stageId: 'st', times: [1]),
        ],
      ),
    );
    await tester.pumpWidget(PaceApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Матч'));
    await tester.pumpAndSettle();
    final participant = find.widgetWithText(ListTile, 'Alpha');
    await tester.scrollUntilVisible(
      participant,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: participant,
        matching: find.byTooltip('Удалить из матча'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();
    expect(store.data.matchExcludedShooters, {'a'});
    expect(store.data.runs.single.id, 'r');
    expect(store.data.shooters.length, 2);
    await tester.scrollUntilVisible(
      find.text('Вернуть стрелка в матч'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Вернуть стрелка в матч'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha').last);
    await tester.pumpAndSettle();
    expect(store.data.matchExcludedShooters, isEmpty);
    expect(store.data.matchRuns.length, 1);
    expect(tester.takeException(), isNull);
  });
}
