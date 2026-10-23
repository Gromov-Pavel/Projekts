import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'store.dart';
import 'domain.dart';

Future<List<int>> trainingBytes(AppData data, String format, {bool match = false}) async {
  String name(String? id) =>
      data.shooters.where((s) => s.id == id).firstOrNull?.name ?? 'Не назначен';
  final headers = [
    'Стрелок',
    'Упражнение',
    'Время',
    'Очки',
    'HF',
    'Фактор',
    'A',
    'C',
    'D',
    'M',
    'NS',
    'P',
    'Зачёт',
  ];
  final rows = data.runs
      .map(
        (r) => [
          name(r.shooterId),
          data.allStages.where((s) => s.id == r.stageId).firstOrNull?.name ??
              'Разминка',
          r.totalTime.toStringAsFixed(2),
          '${r.score}',
          r.hitFactor.toStringAsFixed(4),
          r.major ? 'Major' : 'Minor',
          '${r.alpha}',
          '${r.charlie}',
          '${r.delta}',
          '${r.miss}',
          '${r.noShoot}',
          '${r.procedural}',
          r.selected ? 'Да' : 'Нет',
        ],
      )
      .toList();
  List<List<String>> resultRows(List<Stage> stages) {
    final totals = matchTotals(stages, data.runs.where((r) => stages.any((s) => s.id == r.stageId)).toList());
    final people = [...data.shooters]..sort((a, b) => (totals[b.id] ?? 0).compareTo(totals[a.id] ?? 0));
    final best = totals.values.fold<double>(0, (a, b) => a > b ? a : b);
    return people.asMap().entries.map((e) { final points = totals[e.value.id] ?? 0; return ['${e.key + 1}', e.value.name, points.toStringAsFixed(4), (best > 0 ? points / best * 100 : 0).toStringAsFixed(2)]; }).toList();
  }
  final resultTables = <String, List<List<String>>>{if (match) 'Матч': resultRows(data.stages), if (match) for (var i = 0; i < data.stages.length; i++) '${i + 1}. ${data.stages[i].name}': resultRows([data.stages[i]])};
  late List<int> bytes;
  if (format == 'json') {
    bytes = utf8.encode(jsonEncode(data.toJson()));
  } else if (format == 'xlsx') {
    final workbook = Excel.createExcel();
    final sheet = workbook['Результаты'];
    workbook.delete('Sheet1');
    sheet.appendRow(headers.map(TextCellValue.new).toList());
    for (final r in data.runs) {
      sheet.appendRow([
        TextCellValue(name(r.shooterId)),
        TextCellValue(
          data.allStages.where((s) => s.id == r.stageId).firstOrNull?.name ??
              'Разминка',
        ),
        DoubleCellValue(r.totalTime),
        IntCellValue(r.score),
        DoubleCellValue(r.hitFactor),
        TextCellValue(r.major ? 'Major' : 'Minor'),
        ...[
          r.alpha,
          r.charlie,
          r.delta,
          r.miss,
          r.noShoot,
          r.procedural,
        ].map(IntCellValue.new),
        TextCellValue(r.selected ? 'Да' : 'Нет'),
      ]);
    }
    if (match) {
      final summary = workbook['Матч'];
      for (final table in resultTables.entries) {
        summary.appendRow([TextCellValue(table.key)]);
        summary.appendRow(['Место', 'Стрелок', 'Очки', '%'].map(TextCellValue.new).toList());
        for (final row in table.value) { summary.appendRow(row.map(TextCellValue.new).toList()); }
      }
    }
    bytes = workbook.encode()!;
  } else if (format == 'pdf') {
    final font = pw.Font.ttf(
      await rootBundle.load('assets/NotoSans-Regular.ttf'),
    );
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );
    doc.addPage(
      pw.MultiPage(
        maxPages: 20 + rows.length,
        build: (_) => [
          pw.Text('IPSC тренировОчка — тренировочные результаты'),
          for (final table in resultTables.entries) ...[
            pw.Text(table.key),
            pw.TableHelper.fromTextArray(headers: ['Место', 'Стрелок', 'Очки', '%'], data: table.value, cellStyle: const pw.TextStyle(fontSize: 8)),
          ],
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: headers.take(5).toList(),
            data: rows.map((r) => r.take(5).toList()).toList(),
            cellStyle: const pw.TextStyle(fontSize: 8),
          ),
        ],
      ),
    );
    bytes = await doc.save();
  } else {
    throw ArgumentError('Неизвестный формат');
  }
  return bytes;
}

Future<void> exportTraining(AppData data, String format, {bool match = false}) async {
  final bytes = await trainingBytes(data, format, match: match);
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/pace-${DateTime.now().millisecondsSinceEpoch}.$format',
  );
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path)],
      text: 'IPSC тренировОчка — тренировочные результаты',
    ),
  );
}
