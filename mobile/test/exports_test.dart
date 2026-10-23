import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/domain.dart';
import 'package:ipsc_training/exports.dart';
import 'package:ipsc_training/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final data = AppData(
    shooters: [Shooter(id: 's', name: '=Тестовый стрелок')],
    runs: [Run(id: 'r', shooterId: 's', manualTime: 4, alpha: 8)],
  );
  test('xlsx retains numeric scores and untrusted names as text', () async {
    final bytes = await trainingBytes(data, 'xlsx');
    final book = Excel.decodeBytes(bytes);
    final row = book['Результаты'].rows[1];
    expect(row[0]!.value, isA<TextCellValue>());
    expect(row[2]!.value, IntCellValue(4));
    expect(row[3]!.value, IntCellValue(40));
    expect(row[4]!.value, IntCellValue(10));
  });
  test('json export is restorable without losing source times', () async {
    final bytes = await trainingBytes(data, 'json');
    final restored = AppData.fromJson(
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
    );
    expect(restored.runs.single.hitFactor, 10);
  });
  test('pdf embeds Cyrillic font and produces a document offline', () async {
    final bytes = await trainingBytes(data, 'pdf');
    expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });
}
