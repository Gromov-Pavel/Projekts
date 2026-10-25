import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/video_screen.dart';
import 'package:ipsc_training/video_timeline.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'video_review_test.dart' show ReviewVideoPlatform, settleIO;

class PlayerControlsPlatform extends ReviewVideoPlatform {
  final volumes = <int, double>{};
  final speeds = <int, double>{};
  @override
  Future<void> setVolume(int id, double value) async {
    volumes[id] = value;
  }

  @override
  Future<void> setPlaybackSpeed(int id, double value) async {
    speeds[id] = value;
  }
}

void main() {
  testWidgets(
    'A and B HUD count audio marks and last splits at seek and in full screen; export keeps the same provisional shots',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('pace-hud-');
      final metadata = File('${dir.path}/video-links.json');
      metadata.writeAsStringSync(
        jsonEncode([
          {
            'path': '/test/a.mp4',
            'name': 'Clip A',
            'start': 2.0,
            'syncStatus': 'manual',
            'markers': [3.0],
            'candidates': [3.005, 3.3, 3.6],
            'comparisonPath': '/test/b.mp4',
            'comparisonOffset': 1.0,
            'comparisonCorrection': 0.0,
            'overlay': true,
          },
          {
            'path': '/test/b.mp4',
            'name': 'Clip B',
            'start': 3.0,
            'syncStatus': 'manual',
            'candidates': [4.0, 4.2],
          },
        ]),
      );
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const audio = MethodChannel('pace/audio');
      Map? exported;
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
        if (call.method == 'exportAnalysis') {
          exported = call.arguments as Map;
          throw PlatformException(
            code: 'test',
            message: 'No encoder in widget test',
          );
        }
        return {'frameRate': 30.0};
      });
      final old = VideoPlayerPlatform.instance;
      final platform = PlayerControlsPlatform();
      VideoPlayerPlatform.instance = platform;
      final systemCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          systemCalls.add(call);
          return null;
        },
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String hud(bool b) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(ValueKey(b ? 'video-hud-b' : 'video-hud-a')),
              matching: find.byType(Text),
            ),
          )
          .textSpan!
          .toPlainText();
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
        expect(hud(false), contains('№0/3'));
        expect(hud(true), contains('№0/2'));
        expect(hud(false), contains('—'));
        expect(hud(false), isNot(contains('0.00 с')));
        await tester.scrollUntilVisible(
          find.byType(ShotTimeline),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        tester.widget<ShotTimeline>(find.byType(ShotTimeline)).onSeek(1.4);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('video-hud-a')),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(hud(false), contains('№2/3'));
        expect(hud(false), contains('Сплит: 0.30 с'));
        expect(hud(false), contains('1.30 с'));
        expect(hud(false), isNot(contains('1.40 с')));
        expect(hud(true), contains('1.20 с'));
        expect(hud(true), contains('№2/2'));
        expect(hud(true), contains('Сплит: 0.20 с'));
        tester.widget<ShotTimeline>(find.byType(ShotTimeline)).onSeek(1.55);
        await tester.pumpAndSettle();
        expect(hud(false), contains('1.30 с'));
        tester.widget<ShotTimeline>(find.byType(ShotTimeline)).onSeek(1.9);
        await tester.pumpAndSettle();
        expect(hud(false), contains('1.60 с'));
        expect(hud(true), contains('1.20 с'));
        tester.widget<ShotTimeline>(find.byType(ShotTimeline)).onSeek(.4);
        await tester.pumpAndSettle();
        expect(hud(false), contains('№0/3'));
        expect(hud(false), isNot(contains('1.60 с')));
        tester.widget<ShotTimeline>(find.byType(ShotTimeline)).onSeek(1.4);
        await tester.pumpAndSettle();

        final full = find.byTooltip('Полноэкранный разбор');
        await tester.scrollUntilVisible(
          full,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(full);
        tester.view.physicalSize = const Size(640, 360);
        tester.view.devicePixelRatio = 1;
        await tester.pumpAndSettle();
        expect(hud(false), contains('№2/3'));
        final aRect = tester.getRect(find.byKey(const ValueKey('video-hud-a')));
        final bRect = tester.getRect(find.byKey(const ValueKey('video-hud-b')));
        expect(aRect.right, lessThanOrEqualTo(bRect.left));
        expect(
          tester
              .widget<Container>(find.byKey(const ValueKey('video-hud-a')))
              .decoration,
          isNull,
        );
        expect(find.text('Пуск'), findsNothing);
        expect(
          find.textContaining('Точный кадр зависит от кодека'),
          findsNothing,
        );
        expect(aRect.top, closeTo(bRect.top, 1));
        expect(find.byType(ChoiceChip), findsNothing);
        await tester.tap(find.byTooltip('Настройки плеера'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text('Скорость 0.5×'),
            matching: find.byType(CheckedPopupMenuItem<double>),
          ),
        );

        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Настройки плеера'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text('Звук A'),
            matching: find.byType(CheckedPopupMenuItem<double>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Настройки плеера'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.text('Звук B'),
            matching: find.byType(CheckedPopupMenuItem<double>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('paired-play')));
        await tester.pump();
        expect(platform.volumes, {0: 0.0, 1: 1.0});
        expect(platform.speeds, {0: .5, 1: .5});
        await tester.tap(find.byKey(const ValueKey('paired-play')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Экспорт сравнения A и B'));
        await tester.pumpAndSettle();
        expect(exported!['mode'], 'overlay');
        await tester.tap(find.byTooltip('Закрыть полный экран'));
        await tester.pumpAndSettle();
        expect(
          systemCalls
              .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
              .map((c) => c.arguments),
          [
            [
              'DeviceOrientation.landscapeLeft',
              'DeviceOrientation.landscapeRight',
            ],
            [],
          ],
        );
        expect(exported!['times'], [
          1.0,
          closeTo(1.3, .0001),
          closeTo(1.6, .0001),
        ]);
        expect(exported!['comparisonTimes'], [1.0, closeTo(1.2, .0001)]);
        expect(exported!['primaryLabel'], isNot(contains('авто')));
        expect(exported!['comparisonLabel'], isNot(contains('проверить')));
        final saved = jsonDecode(metadata.readAsStringSync()) as List;
        expect(saved[0]['markers'], [3.0]);
        expect(saved[0]['candidates'], [3.005, 3.3, 3.6]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settleIO(tester);
        VideoPlayerPlatform.instance = old;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
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
    },
  );
}
