import 'dart:math';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ipsc_training/video_screen.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/video_analysis.dart';

void main() {
  List<AudioFrame> fixture(String name) {
    final data = jsonDecode(
      File('test/fixtures/audio/$name.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    return (data['frames'] as List)
        .map(
          (row) => AudioFrame(
            (row[0] as num).toDouble(),
            (row[1] as num).toDouble(),
            (row[2] as num).toDouble(),
            (row[3] as num).toDouble(),
          ),
        )
        .toList();
  }

  test('development real features retain quiet and masked stable spectral candidates', () {
    // Spectral intervals inspected during development, not labelled beep ground truth.
    for (final expected in {
      'sample01': .9,
      'sample02': 1.02,
      'sample03': 2.06,
      'sample04': 1.0,
      'sample05': 1.241604,
      'sample06': 2.08,
      'sample07': 2.421604,
    }.entries) {
      final result = analyzeAudio(fixture(expected.key));
      expect(result.beep, closeTo(expected.value, .021), reason: expected.key);
      expect(result.candidates.first.frequencyHz, 2300);
      expect(result.candidates.first.duration, greaterThanOrEqualTo(.18));
    }
    // The earlier voiced/drifting 1.45–1.65 kHz segment is not the stable 2.3 kHz interval.
    expect(
      analyzeAudio(fixture('sample03')).candidates
          .where((b) => b.time < 1.2),
      isEmpty,
    );
  });

  test('dominant harmonic switching preserves the first tonal onset', () {
    for (final pattern in [
      [1500.0, 3000.0, 4500.0],
      [3000.0, 1500.0, 4500.0],
    ]) {
      final frames = List.generate(
        80,
        (i) => AudioFrame(
          i * .02,
          i >= 10 && i < 40 ? .1 : 0,
          i >= 10 && i < 40 ? .8 : 0,
          pattern[((i / 5).floor()) % pattern.length],
        ),
      );
      expect(analyzeAudio(frames).beep, closeTo(.2, .001));
    }
    // Promoted from the initial holdout after inspecting the harmonic counterexample.
    final real = analyzeAudio(fixture('sample08'));
    expect(real.beep, closeTo(2.12, .021));
  });

  test(
    'attenuation preserves timing without requiring the old absolute loudness',
    () {
      final frames = fixture('sample02')
          .map((f) => AudioFrame(f.time, f.rms / 20, f.tone, f.frequencyHz))
          .toList();
      expect(analyzeAudio(frames).beep, closeTo(1.02, .021));
    },
  );

  test('tone at media boundary is a clipped candidate and never a precise automatic zero', () {
    final result = analyzeAudio(fixture('sample09'));
    expect(result.beep, isNull);
    expect(result.candidates.single.atBoundary, isTrue);
    expect(result.candidates.single.time, 0);
    expect(result.candidates.single.confidence, lessThanOrEqualTo(.5));
  });

  test('frequency drift and continuous hum are not timer proposals', () {
    final drift = List.generate(
      50,
      (i) => AudioFrame(i * .02, .1, .8, 1250 + i * 50.0),
    );
    final hum = List.generate(200, (i) => AudioFrame(i * .02, .1, .8, 2300));
    expect(analyzeAudio(drift).candidates, isEmpty);
    expect(analyzeAudio(hum).candidates, isEmpty);
  });

  test('legacy three-field features remain accepted and multiple tones stay separate', () {
    final frames = List.generate(
      80,
      (i) => AudioFrame(
        i * .02,
        (i >= 10 && i < 25) || (i >= 40 && i < 55) ? .01 : 0,
        (i >= 10 && i < 25) || (i >= 40 && i < 55) ? .8 : 0,
      ),
    );
    final result = analyzeAudio(frames);
    expect(result.candidates.map((c) => c.time), [.2, .8]);
    expect(result.beep, .2);
  });
  test('video alignment preserves timer times and pre-start shot count', () {
    expect(videoShotTimes(start: 2, timerTimes: [.8, 1.1], markers: [9]), [
      .8,
      1.1,
    ]);
    expect(videoShotTimes(start: 2, markers: [3.5, 1, 2.4]), [
      closeTo(.4, .0001),
      1.5,
    ]);
    expect(videoShotIndex([0, .8], -.01), -1);
    expect(videoShotIndex([.8, 1.1], 1), 0);
    expect(videoSplit([.8, 1.1], 1), closeTo(.3, .0001));
  });
  test('preview counts candidates after the signal, dedups confirmed marks and prefers timer shots', () {
    final times = videoShotTimes(
      start: 2,
      markers: [3.0],
      candidates: [1.9, 3.005, 3.3, 3.6],
    );
    expect(times, [1.0, closeTo(1.3, .0001), closeTo(1.6, .0001)]);
    expect(videoShotIndex(times, .99), -1);
    expect(videoShotIndex(times, 1.4), 1);
    expect(videoSplit(times, 1), closeTo(.3, .0001));
    expect(
      videoShotTimes(
        start: 2,
        timerTimes: [.8, 1.1],
        markers: [3],
        candidates: [3.3],
      ),
      [.8, 1.1],
    );
  });
  test('metadata rejects malformed or partial video lists', () {
    expect(() => decodeVideoLinks('{'), throwsFormatException);
    expect(
      () => decodeVideoLinks('[{"path":"a","name":"ok"},{"path":2}]'),
      throwsFormatException,
    );
    final entries = decodeVideoLinks(
      '[{"path":"a","name":"A","comparisonPath":"b","comparisonOffset":-1.2,"overlay":true}]',
    );
    expect(entries.single['comparisonPath'], 'b');
    expect(entries.single['comparisonOffset'], -1.2);
  });

  testWidgets(
    'corrupt metadata blocks imports and retry preserves the original',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('video-metadata-');
      final file = File('${directory.path}/video-links.json');
      const original = '{broken json with valuable links';
      file.writeAsStringSync(original);
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => directory.path,
      );
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: VideoScreen(runs: [], shooters: []),
            ),
          ),
        );
        for (var attempt = 0; attempt < 8; attempt++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          });
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(find.textContaining('Исходный файл сохранён'), findsOneWidget);
        final importButton = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Выбрать видео'),
        );
        expect(importButton.onPressed, isNull);
        await tester.tap(find.text('Повторить чтение списка видео'));
        for (var attempt = 0; attempt < 8; attempt++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          });
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(file.readAsStringSync(), original);
        expect(find.textContaining('Исходный файл сохранён'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        directory.deleteSync(recursive: true);
      }
    },
  );
  test('silence and isolated impulses never become a timer beep', () {
    final samples = List<double>.filled(16000, 0);
    samples[3200] = 1;
    expect(analyzeAudio(pcmFeatures(samples, 16000)).beep, isNull);
  });
  test('finds sustained timer tone at actual sample rate', () {
    for (final rate in [16000, 44100]) {
      final samples = List<double>.generate(
        rate,
        (i) => i >= rate * .3 && i < rate * .5
            ? .3 * sin(2 * pi * 2300 * i / rate)
            : 0,
      );
      expect(analyzeAudio(pcmFeatures(samples, rate)).beep, closeTo(.3, .025));
    }
  });
  test('broadband burst is an uncertain shot, never a beep', () {
    final random = Random(42);
    final samples = List<double>.generate(
      16000,
      (i) => i >= 6400 && i < 6720 ? random.nextDouble() * 1.6 - .8 : 0,
    );
    final result = analyzeAudio(pcmFeatures(samples, 16000));
    expect(result.beep, isNull);
    expect(result.shotCandidates, hasLength(1));
    expect(result.shotCandidates.single, closeTo(.4, .02));
  });
}
