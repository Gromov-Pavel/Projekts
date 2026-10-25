import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/domain.dart';
import 'package:ipsc_training/video_screen.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class ReviewVideoPlatform extends VideoPlayerPlatform {
  final positions = <int, Duration>{};
  @override
  Future<void> init() async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = positions.length;
    positions[id] = Duration.zero;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 15),
      size: const Size(640, 360),
    ),
  );
  @override
  Future<void> dispose(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async => positions[playerId]!;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.black);
}

Future<void> settleIO(WidgetTester tester, {bool Function()? until}) async {
  final deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 20)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final import = find.widgetWithText(FilledButton, 'Выбрать видео');
    final ready =
        import.evaluate().isEmpty ||
        tester.widget<FilledButton>(import).onPressed != null;
    final loading =
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    if (ready && !loading && (until == null || until())) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail(
    'Video UI did not finish its asynchronous file operations within 20 seconds',
  );
}

void main() {
  testWidgets(
    'two independently linked videos share start, shot seek and full screen at 320dp',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      final directory = Directory.systemTemp.createTempSync(
        'pace-video-review-',
      );
      final metadata = File('${directory.path}/video-links.json');
      metadata.writeAsStringSync(
        jsonEncode([
          {
            'path': '/test/a.mp4',
            'name': 'Clip A',
            'runId': 'a',
            'start': 2.0,
            'comparisonPath': '/test/b.mp4',
            'comparisonOffset': 6.0,
          },
          {
            'path': '/test/b.mp4',
            'name': 'Clip B',
            'runId': 'b',
            'start': 8.0,
            'candidates': [.3],
          },
        ]),
      );
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const audio = MethodChannel('pace/audio');
      MethodCall? exported;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        paths,
        (_) async => directory.path,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(audio, (
        call,
      ) async {
        if (call.method == 'prepareVideoPreview') {
          return {'path': call.arguments['path'], 'frameRate': 30.0};
        }
        if (call.method == 'exportAnalysis') {
          exported = call;
          throw PlatformException(
            code: 'test',
            message: 'No hardware encoder in widget test',
          );
        }
        return {'frameRate': 30.0, 'duration': 15.0};
      });
      final oldPlatform = VideoPlayerPlatform.instance;
      final platform = ReviewVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VideoScreen(
                runs: [
                  Run(id: 'a', times: [.8, 1.1]),
                  Run(id: 'b', times: [.9, 1.2]),
                ],
                shooters: const [],
              ),
            ),
          ),
        );
        await settleIO(tester);
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Clip A').last);
        await settleIO(tester);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('shot-timeline-track')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('shot-timeline-track')),
          findsOneWidget,
        );

        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byTooltip('Следующий выстрел'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Следующий выстрел'));
        await tester.pumpAndSettle();
        expect(platform.positions[0], const Duration(milliseconds: 2800));
        expect(platform.positions[1], const Duration(milliseconds: 8800));
        await tester.scrollUntilVisible(
          find.byTooltip('Полноэкранный разбор'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Полноэкранный разбор'));
        await settleIO(
          tester,
          until: () =>
              find.byTooltip('Закрыть полный экран').evaluate().isNotEmpty,
        );
        expect(find.byTooltip('Закрыть полный экран'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Закрыть полный экран'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Ручная синхронизация и выстрелы'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Ручная синхронизация и выстрелы'));
        await tester.pumpAndSettle();
        final startB = find.text('Старт: 8.00 с');
        await tester.scrollUntilVisible(
          startB,
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(startB);
        await tester.pumpAndSettle();
        await tester.tap(startB);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).last, '7');
        await tester.tap(find.text('Сохранить'));
        await settleIO(
          tester,
          until: () =>
              platform.positions[1] == const Duration(milliseconds: 7000),
        );
        final saved = jsonDecode(metadata.readAsStringSync()) as List;
        expect(saved[0]['start'], 2.0);
        expect(saved[0]['runId'], 'a');
        expect(saved[0]['comparisonOffset'], 5.0);
        expect(saved[1]['start'], 7.0);
        expect(saved[1]['runId'], 'b');
        expect(platform.positions[1], const Duration(milliseconds: 7000));
        expect(tester.takeException(), isNull);
        final export = find.text('Экспорт сравнения A и B');
        await tester.scrollUntilVisible(
          export,
          -400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(export);
        await tester.pumpAndSettle();
        await tester.tap(export);
        await tester.pumpAndSettle();
        expect(exported?.arguments['mode'], 'sideBySide');
        expect(exported?.arguments['start'], 2.0);
        expect(exported?.arguments['comparisonStart'], 7.0);
        expect(exported?.arguments['comparisonCorrection'], 0.0);
        expect(exported?.arguments['times'], [.8, 1.1]);
        expect(exported?.arguments['comparisonTimes'], [.9, 1.2]);
        Future<void> selectPrimary(String from, String label) async {
          final dropdown = find.byKey(ValueKey('video:/test/$from.mp4'));
          await tester.scrollUntilVisible(
            dropdown,
            -400,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(dropdown);
          await tester.pumpAndSettle();
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await settleIO(tester);
        }

        await selectPrimary('a', 'Clip B');
        final primaryStartB = find.text('Старт: 7.00 с');
        await tester.scrollUntilVisible(
          primaryStartB,
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(primaryStartB);
        await tester.pumpAndSettle();
        await tester.tap(primaryStartB);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).last, '6');
        await tester.tap(find.text('Сохранить'));
        await settleIO(
          tester,
          until: () =>
              (jsonDecode(metadata.readAsStringSync())
                  as List)[0]['comparisonOffset'] ==
              4.0,
        );
        final afterEdit = jsonDecode(metadata.readAsStringSync()) as List;
        expect(afterEdit[0]['comparisonCorrection'], 0.0);
        expect(afterEdit[0]['comparisonOffset'], 4.0);
        await selectPrimary('b', 'Clip A');
        await tester.scrollUntilVisible(
          find.byTooltip('Следующий выстрел'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Следующий выстрел'));
        await tester.pumpAndSettle();
        expect(platform.positions[3], const Duration(milliseconds: 2800));
        expect(platform.positions[4], const Duration(milliseconds: 6800));
        expect(tester.takeException(), isNull);
        final bRunPicker = find.byKey(const ValueKey('run:/test/b.mp4:b'));
        await tester.scrollUntilVisible(
          bRunPicker,
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(bRunPicker);
        await tester.pumpAndSettle();
        await tester.tap(bRunPicker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Без таймера · метки по видео').last);
        await settleIO(tester);
        final editor = find.textContaining('Метки B ·');
        await tester.scrollUntilVisible(
          editor,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final candidate = find.text('Кандидат · 0.30 с');
        await tester.scrollUntilVisible(
          candidate,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(candidate);
        await tester.pumpAndSettle();
        expect(platform.positions[3], Duration.zero);
        expect(platform.positions[4], const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await settleIO(tester);
      } finally {
        VideoPlayerPlatform.instance = oldPlatform;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          paths,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          audio,
          null,
        );
        directory.deleteSync(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
