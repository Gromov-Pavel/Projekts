import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/video_screen.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'video_review_test.dart' show ReviewVideoPlatform, settleIO;

class SyncPlatform extends ReviewVideoPlatform {
  final volumes = <int, double>{};
  final played = <int>[];
  int seeks = 0;
  final mixing = <bool>[];
  @override
  Future<void> setMixWithOthers(bool value) async {
    mixing.add(value);
  }

  @override
  Future<void> play(int id) async {
    played.add(id);
  }

  @override
  Future<void> setVolume(int id, double value) async {
    volumes[id] = value;
  }

  @override
  Future<void> seekTo(int id, Duration position) async {
    seeks++;
    await super.seekTo(id, position);
  }
}

List<List<double>> toneAt(double start) => List.generate(300, (i) {
  final time = i * .02;
  final tonal = time >= start && time < start + .4;
  return [time, tonal ? .015 : .001, tonal ? .8 : .01, tonal ? 2300.0 : 1300.0];
});

void main() {
  for (final existingB in [true, false]) {
    testWidgets(
      'automatic common start preserves correction with B ${existingB ? 'already marked' : 'also unprocessed'}',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1200);
        tester.view.devicePixelRatio = 1;
        final dir = Directory.systemTemp.createTempSync('pace-auto-sync-');
        final metadata = File('${dir.path}/video-links.json');
        metadata.writeAsStringSync(
          jsonEncode([
            {
              'path': '/test/a.mp4',
              'name': 'Clip A',
              'start': 0.0,
              'syncStatus': 'unprocessed',
              'comparisonPath': '/test/b.mp4',
              'comparisonOffset': existingB ? 8.0 : 0.0,
              'comparisonCorrection': 0.0,
            },
            {
              'path': '/test/b.mp4',
              'name': 'Clip B',
              'start': existingB ? 8.0 : 0.0,
              'syncStatus': existingB ? 'manual' : 'unprocessed',
            },
          ]),
        );
        const paths = MethodChannel('plugins.flutter.io/path_provider');
        const audio = MethodChannel('pace/audio');
        final analysisPaths = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          paths,
          (_) async => dir.path,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(audio, (
          call,
        ) async {
          if (call.method == 'prepareVideoPreview') {
            return {'path': call.arguments['path']};
          }
          if (call.method == 'videoInfo') return {'frameRate': 30.0};
          if (call.method == 'analyze') {
            final path = call.arguments['path'] as String;
            analysisPaths.add(path);
            return toneAt(path.endsWith('a.mp4') ? 2.0 : 3.0);
          }
          return null;
        });
        final old = VideoPlayerPlatform.instance;
        final platform = SyncPlatform();
        VideoPlayerPlatform.instance = platform;
        try {
          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(
                body: VideoScreen(runs: [], shooters: []),
              ),
            ),
          );
          await settleIO(tester);
          await tester.tap(find.byType(DropdownButtonFormField<String>).first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Clip A').last);
          await settleIO(tester);
          expect(
            analysisPaths,
            existingB ? ['/test/a.mp4'] : ['/test/a.mp4', '/test/b.mp4'],
          );
          expect(platform.mixing, [true, true]);
          expect(platform.positions[0], const Duration(seconds: 2));
          expect(platform.positions[1], Duration(seconds: existingB ? 8 : 3));
          final saved = jsonDecode(metadata.readAsStringSync()) as List;
          expect(saved[0]['comparisonCorrection'], 0.0);
          expect(saved[0]['comparisonOffset'], existingB ? 6.0 : 1.0);
          final play = find.byKey(const ValueKey('paired-play'));
          await tester.scrollUntilVisible(
            play,
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(play);
          await tester.pump();
          expect(platform.played.toSet(), {0, 1});
          expect(platform.positions[0], const Duration(seconds: 2));
          expect(platform.positions[1], Duration(seconds: existingB ? 8 : 3));
          final seeks = platform.seeks;
          await tester.pump(const Duration(milliseconds: 1100));
          await tester.pump();
          expect(
            platform.seeks,
            seeks,
            reason: 'Unchanged sparse samples must not cause repeated B seeks',
          );
          await tester.tap(play);
          await tester.pumpAndSettle();
          if (!existingB) {
            await tester.ensureVisible(
              find.text('Ручная синхронизация и выстрелы'),
            );
            await tester.tap(find.text('Ручная синхронизация и выстрелы'));
            await tester.pumpAndSettle();

            final inspectB = find.text('Проверить старт B');
            await tester.scrollUntilVisible(
              inspectB,
              350,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            await tester.tap(inspectB);
            await tester.pumpAndSettle();
            expect(platform.volumes[0], 0.0);
            expect(platform.volumes[1], 1.0);
            expect(platform.positions[1], Duration.zero);
            final mark = find.text('Сигнал здесь').last;
            await tester.ensureVisible(mark);
            await tester.pumpAndSettle();
            await tester.tap(mark);
            await settleIO(
              tester,
              until: () {
                final current = jsonDecode(metadata.readAsStringSync()) as List;
                return current[1]['syncStatus'] == 'manual' &&
                    current[1]['start'] == 0.0 &&
                    platform.positions[0] == const Duration(seconds: 2) &&
                    platform.positions[1] == Duration.zero;
              },
            );
            expect(platform.positions[0], const Duration(seconds: 2));
            expect(platform.positions[1], Duration.zero);
            final marked = jsonDecode(metadata.readAsStringSync()) as List;
            expect(marked[1]['start'], 0.0);
            expect(marked[1]['syncStatus'], 'manual');
            await tester.scrollUntilVisible(
              play,
              -350,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            await tester.tap(play);
            await tester.pump();
            expect(platform.volumes[0], 1.0);
            expect(platform.volumes[1], 0.0);
            await tester.tap(play);
            await tester.pumpAndSettle();
            final bStart = find.text('Старт: 0.00 с');
            await tester.scrollUntilVisible(
              bStart,
              350,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            await tester.tap(bStart);
            await tester.pumpAndSettle();
            await tester.enterText(find.byType(TextFormField).last, '-0.2');
            await tester.tap(find.text('Сохранить'));
            await settleIO(
              tester,
              until: () =>
                  (jsonDecode(metadata.readAsStringSync())
                      as List)[1]['start'] ==
                  -.2,
            );
            expect(platform.positions[0], const Duration(milliseconds: 2200));
            expect(platform.positions[1], Duration.zero);
            expect(
              (jsonDecode(metadata.readAsStringSync()) as List)[1]['start'],
              -.2,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await settleIO(tester);
        } finally {
          VideoPlayerPlatform.instance = old;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            paths,
            null,
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            audio,
            null,
          );
          dir.deleteSync(recursive: true);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }
  testWidgets('missing beep never silently becomes a synchronized zero start', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('pace-missing-start-');
    File('${dir.path}/video-links.json').writeAsStringSync(
      jsonEncode([
        {'path': '/test/a.mp4', 'name': 'Clip A', 'start': 0.0},
      ]),
    );
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const audio = MethodChannel('pace/audio');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => dir.path,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(audio, (
      call,
    ) async {
      if (call.method == 'prepareVideoPreview') {
        return {'path': call.arguments['path']};
      }
      if (call.method == 'analyze') return <List<double>>[];
      return {'frameRate': 30.0};
    });
    final old = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = SyncPlatform();
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VideoScreen(runs: [], shooters: []),
          ),
        ),
      );
      await settleIO(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clip A').last);
      await settleIO(tester);
      final play = find.byKey(const ValueKey('paired-play'));
      await tester.scrollUntilVisible(
        play,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(play).onPressed, isNull);
      expect(
        (jsonDecode(
          File('${dir.path}/video-links.json').readAsStringSync(),
        ) as List).first['syncStatus'],
        'missing',
      );
      await tester.pumpWidget(const SizedBox());
      await settleIO(tester);
    } finally {
      VideoPlayerPlatform.instance = old;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        audio,
        null,
      );
      dir.deleteSync(recursive: true);
    }
  });
}
