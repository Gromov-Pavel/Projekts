import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/domain.dart';

const logHeader =
    'id,ts,time,first,shots,splits,device,tag,notes,reps,images,score\n';
const logRow =
    '86,2025-04-17T13:31:38.508369,357,74,10,"74,101,127,173,205,241,272,301,329,357",M1A2 3273,"""Сторощук""",,,,\n';

void main() {
  test('minor, major, penalties and time precedence', () {
    final run = Run(
      id: 'r',
      times: [1, 2, 4],
      manualTime: 9,
      alpha: 10,
      charlie: 2,
      delta: 3,
      miss: 1,
      noShoot: 1,
      procedural: 1,
    );
    expect(run.score, 29);
    expect(run.copyWith(major: true).score, 34);
    expect(run.totalTime, 4);
    expect(run.hitFactor, 7.25);
    expect(run.splits, [1, 1, 2]);
    expect(run.copyWith(alpha: 0).score, 0);
    expect(Run(id: 'r').hitFactor, 0);
    expect(run.copyWith(times: []).totalTime, 9);
    expect(run.copyWith(times: [], manualTime: null).totalTime, 0);
  });
  test('models survive JSON and remain immutable', () {
    final run = Run(id: 'r', shooterId: 's', stageId: 'st', times: [1, 2]);
    final restored = Run.fromJson(jsonDecode(jsonEncode(run.toJson())));
    expect(restored.toJson(), run.toJson());
    expect(() => restored.times.add(3), throwsUnsupportedError);
    expect(restored.copyWith(stageId: null).stageId, null);
    final stage = Stage(id: 'st', name: 'Stage', paper: 3, steel: 2);
    expect(Stage.fromJson(stage.toJson()).maxPoints, 40);
    expect(Shooter.fromJson(Shooter(id: 's', name: 'S').toJson()).name, 'S');
  });
  test(
    'timestamps and counts are validated at construction and JSON boundary',
    () {
      for (final times in [
        [0.0],
        [-1.0],
        [double.nan],
        [double.infinity],
        [1.0, 1.0],
        [2.0, 1.0],
      ]) {
        expect(() => Run(id: 'r', times: times), throwsFormatException);
      }
      expect(() => Run(id: 'r', alpha: -1), throwsFormatException);
      expect(() => Run(id: 'r', manualTime: double.nan), throwsFormatException);
      expect(
        () => Stage(id: 's', name: 'S', hitsPerPaper: 0),
        throwsFormatException,
      );
      final json = Run(id: 'r').toJson();
      for (final change in <String, dynamic>{
        'alpha': 1.2,
        'times': ['1'],
        'selected': 'yes',
        'createdAt': 'garbage',
        'shooterId': 5,
      }.entries) {
        expect(
          () => Run.fromJson({...json, change.key: change.value}),
          throwsFormatException,
        );
      }
    },
  );
  test('match totals compare selected runs per stage and reject ambiguity', () {
    final stage = Stage(id: 'st', name: 'Stage', paper: 10);
    final a = Run(
      id: 'a',
      shooterId: 'a',
      stageId: 'st',
      manualTime: 10,
      alpha: 20,
      selected: true,
    );
    final b = Run(
      id: 'b',
      shooterId: 'b',
      stageId: 'st',
      manualTime: 20,
      alpha: 20,
      selected: true,
    );
    expect(matchTotals([stage], [a, b, a.copyWith(selected: false)]), {
      'a': 100.0,
      'b': 50.0,
    });
    expect(() => matchTotals([stage], [a, a]), throwsFormatException);
    expect(() => matchTotals([], [a]), throwsFormatException);
    expect(matchTotals([stage], [a.copyWith(alpha: 0), b.copyWith(alpha: 0)]), {
      'a': 0.0,
      'b': 0.0,
    });
  });
  test(
    'real export representative uses cumulative hundredths and quoted tags',
    () {
      final result = importPractiScoreCsv(logHeader + logRow + logRow);
      expect(result.runs.length, 1);
      expect(result.shooters.single.name, 'Сторощук');
      final run = result.runs.single;
      expect(run.times.first, .74);
      expect(run.totalTime, 3.57);
      expect(run.times.length, 10);
      expect(run.splits[1], closeTo(.27, .00001));
      expect(run.score, 0);
      expect(run.selected, false);
      expect(run.stageId, null);
      expect(run.id, importPractiScoreCsv(logHeader + logRow).runs.single.id);
      expect(run.shooterId, result.shooters.single.id);
    },
  );
  test('CSV accepts quoted comma, newline, escaped quote and CRLF', () {
    final result = importPractiScoreCsv(
      '${logHeader}1,2025-04-17T13:31:38,100,100,1,100,device,"A, B","Line one\nLine ""two""",,,\r\n',
    );
    expect(result.shooters.single.name, 'A, B');
    expect(result.runs.single.totalTime, 1);
  });
  test('CSV rejects inconsistent and malformed records atomically', () {
    for (final row in [
      logRow.replaceFirst('357,74,10', '357,74,9'),
      logRow.replaceFirst('357,74,10', '358,74,10'),
      logRow.replaceFirst('357,74,10', '357,75,10'),
      logRow.replaceFirst('74,101,127', '74,74,127'),
      logRow.replaceFirst('357,74,10', '-1,74,10'),
      logRow.replaceFirst('2025-04-17T13:31:38.508369', 'bad'),
      logRow.replaceFirst('"74,101', '"74"x,101'),
    ]) {
      expect(
        () => importPractiScoreCsv(logHeader + row),
        throwsFormatException,
      );
    }
    expect(
      () => importPractiScoreCsv('$logHeader"unterminated'),
      throwsFormatException,
    );
    expect(() => importPractiScoreCsv('bad\n1'), throwsFormatException);
    expect(
      () => importPractiScoreCsv(
        logHeader + logRow + logRow.replaceFirst('Сторощук', 'Другой'),
      ),
      throwsFormatException,
    );
  });
}
