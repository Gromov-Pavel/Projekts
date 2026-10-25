import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/domain.dart';
import 'package:ipsc_training/store.dart';

void main() {
  late Directory directory;
  late TrainingStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ipsc-store-test');
    store = TrainingStore(directory: directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  AppData people(String name) => AppData(
    shooters: [Shooter(id: 's', name: name)],
  );

  test('archive groups preserve completed matches and reject forged stage references', () {
    final data = AppData(
      stages: [Stage(id: 'st', name: 'One')],
    );
    data.newMatch();
    final restored = AppData.fromJson(data.toJson());
    expect(restored.archivedMatches.single.stageIds, ['st']);
    expect(restored.stages, isEmpty);
    restored.newMatch();
    expect(restored.archivedMatches, hasLength(1));
    final old = AppData.fromJson({...data.toJson()}..remove('archivedMatches'));
    expect(old.archivedMatches.single.stageIds, ['st']);
    expect(old.archivedMatches.single.id, 'legacy-archive');
    expect(
      () => AppData.fromJson({
        ...data.toJson(),
        'archivedMatches': [
          {
            'id': 'bad',
            'createdAt': DateTime.now().toIso8601String(),
            'stageIds': ['missing'],
          },
        ],
      }),
      throwsFormatException,
    );
  });

  test('first pass defaults to scoring, chosen replacement survives, new match preserves history', () async {
    final data = AppData(
      shooters: [
        Shooter(id: 'a', name: 'A'),
        Shooter(id: 'b', name: 'B'),
      ],
      stages: [Stage(id: 'st', name: 'Stage', paper: 5)],
      runs: [
        Run(
          id: 'later',
          shooterId: 'a',
          stageId: 'st',
          manualTime: 20,
          alpha: 10,
          createdAt: DateTime(2026, 2),
        ),
        Run(
          id: 'first',
          shooterId: 'a',
          stageId: 'st',
          manualTime: 10,
          alpha: 10,
          createdAt: DateTime(2026, 1),
        ),
        Run(
          id: 'other',
          shooterId: 'b',
          stageId: 'st',
          manualTime: 20,
          alpha: 10,
        ),
      ],
    );
    await store.save(data);
    var saved = await store.load();
    expect(saved.runs.singleWhere((r) => r.id == 'first').selected, true);
    expect(matchTotals(saved.stages, saved.matchRuns), {'a': 50.0, 'b': 25.0});
    saved.runs[0] = saved.runs[0].copyWith(selected: true);
    saved.runs[1] = saved.runs[1].copyWith(selected: false);
    await store.save(saved);
    saved = await store.load();
    expect(saved.runs.first.selected, true);
    saved.newMatch();
    await store.save(saved);
    saved = await store.load();
    expect(saved.stages, isEmpty);
    expect(saved.archivedStages.single.name, 'Stage');
    expect(saved.runs, hasLength(3));
    expect(saved.matchRuns, isEmpty);
    expect(saved.runs.first.selected, true);
  });

  test(
    'first load is empty; writes serialize and snapshot immediately',
    () async {
      expect((await store.load()).runs, isEmpty);
      final first = people('first');
      final a = store.save(first);
      first.shooters.clear();
      final b = store.save(people('second'));
      await Future.wait([a, b]);
      expect((await store.load()).shooters.single.name, 'second');
      expect((await store.restoreBackup()).shooters.single.name, 'first');
    },
  );
  test('corruption is preserved; save refuses; recovery is explicit', () async {
    await store.save(people('first'));
    await store.save(people('second'));
    final primary = File('${directory.path}/training.json');
    await primary.writeAsString('{broken');
    await expectLater(store.load(), throwsA(isA<StoreException>()));
    await expectLater(
      store.save(people('third')),
      throwsA(isA<StoreException>()),
    );
    expect(await primary.readAsString(), '{broken');
    expect((await store.restoreBackup()).shooters.single.name, 'first');
    expect((await store.load()).shooters.single.name, 'first');
    final preserved = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.corrupt-'))
        .single;
    expect(await preserved.readAsString(), '{broken');
    await store.save(people('third'));
    expect((await store.load()).shooters.single.name, 'third');
  });
  test('missing primary with backup requires explicit recovery', () async {
    await store.save(people('first'));
    await store.save(people('second'));
    await File('${directory.path}/training.json').delete();
    await expectLater(store.load(), throwsA(isA<StoreException>()));
    await expectLater(
      store.save(people('third')),
      throwsA(isA<StoreException>()),
    );
    expect((await store.restoreBackup()).shooters.single.name, 'first');
  });
  test('invalid backup does not alter primary', () async {
    await store.save(people('first'));
    await File('${directory.path}/training.backup.json')
        .writeAsString('invalid');
    await expectLater(store.restoreBackup(), throwsA(isA<StoreException>()));
    expect((await store.load()).shooters.single.name, 'first');
  });
  test(
    'calculator variants roundtrip with bounds and old schema support',
    () async {
      final variant = Run(id: 'calc', manualTime: 2, alpha: 10);
      final data = AppData(calculations: [variant]);
      await store.save(data);
      expect(
        (await store.load()).calculations.single.toJson(),
        variant.toJson(),
      );
      final legacy = data.toJson()..remove('calculations');
      expect(AppData.fromJson(legacy).calculations, isEmpty);
      expect(
        () => AppData.fromJson(
          AppData(calculations: [variant, variant]).toJson(),
        ),
        throwsFormatException,
      );
      expect(
        () => AppData.fromJson(
          AppData(calculations: List.generate(6, (i) => Run(id: 'calc-$i')))
              .toJson(),
        ),
        throwsFormatException,
      );
      final forged = data.toJson();
      forged['calculations'] = [
        {...variant.toJson(), 'alpha': -1},
      ];
      expect(() => AppData.fromJson(forged), throwsFormatException);
    },
  );
  test(
    'stage capacity changes and forged scores fail before writing',
    () async {
      final stage = Stage(id: 'st', name: 'S', paper: 2, steel: 1);
      final run = Run(
        id: 'r',
        shooterId: 's',
        stageId: 'st',
        alpha: 2,
        charlie: 2,
        delta: 1,
        selected: true,
        manualTime: 5,
      );
      final valid = AppData(
        shooters: people('A').shooters,
        stages: [stage],
        runs: [run],
      );
      await store.save(valid);
      final primary = File('${directory.path}/training.json');
      final original = await primary.readAsString();
      final reduced = AppData(
        shooters: valid.shooters,
        stages: [stage.copyWith(paper: 1)],
        runs: valid.runs,
      );
      await expectLater(store.save(reduced), throwsFormatException);
      expect(await primary.readAsString(), original);
      final forged = valid.toJson();
      forged['runs'] = [run.copyWith(delta: 2).toJson()];
      expect(() => AppData.fromJson(forged), throwsFormatException);
      expect(await primary.readAsString(), original);
      expect((await store.load()).runs.single.alpha, 2);
      expect(
        AppData.fromJson(
          AppData(
            shooters: valid.shooters,
            stages: [stage],
            runs: [run.copyWith(alpha: 0)],
          ).toJson(),
        ).runs.length,
        1,
      );
    },
  );
  test(
    'schema enforces IDs, references, selected uniqueness and size',
    () async {
      expect(
        () => AppData.fromJson({'schemaVersion': 2}),
        throwsFormatException,
      );
      final data = people('name');
      expect(
        () => AppData.fromJson({...data.toJson(), 'runs': {}}),
        throwsFormatException,
      );
      await expectLater(
        store.save(
          AppData(
            shooters: [
              Shooter(id: 's', name: 'A'),
              Shooter(id: 's', name: 'B'),
            ],
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.save(
          AppData(
            runs: [Run(id: 'r', shooterId: 'missing')],
          ),
        ),
        throwsFormatException,
      );
      final run = Run(id: 'r', shooterId: 's', stageId: 'st', selected: true);
      await expectLater(
        store.save(
          AppData(
            shooters: data.shooters,
            stages: [Stage(id: 'st', name: 'S')],
            runs: [
              run,
              Run(id: 'other', shooterId: 's', stageId: 'st', selected: true),
            ],
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.save(people('x' * (5 * 1024 * 1024))),
        throwsFormatException,
      );
      expect((await store.load()).shooters, isEmpty);
    },
  );
  test(
    'removing a match participant preserves history and archive membership',
    () {
      final data = AppData(
        shooters: [
          Shooter(id: 'a', name: 'A'),
          Shooter(id: 'b', name: 'B'),
        ],
        stages: [Stage(id: 'st', name: 'S')],
        runs: [
          Run(id: 'ra', shooterId: 'a', stageId: 'st', times: [1]),
          Run(id: 'rb', shooterId: 'b', stageId: 'st', times: [2]),
        ],
      );
      data.matchExcludedShooters.add('a');
      final restored = AppData.fromJson(data.toJson());
      expect(restored.matchShooters.map((s) => s.id), ['b']);
      expect(restored.matchRuns.map((r) => r.id), ['rb']);
      expect(restored.runs.length, 2);
      expect(restored.shooters.length, 2);
      restored.newMatch();
      expect(restored.archivedMatches.single.excludedShooterIds, ['a']);
      expect(restored.matchShooters.length, 2);
      expect(restored.runs.length, 2);
      final legacy = data.toJson()..remove('matchExcludedShooters');
      expect(AppData.fromJson(legacy).matchShooters.length, 2);
      expect(
        () => AppData.fromJson({
          ...data.toJson(),
          'matchExcludedShooters': ['missing'],
        }),
        throwsFormatException,
      );
    },
  );
}
