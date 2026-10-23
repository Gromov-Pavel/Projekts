import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipsc_training/domain.dart';
import 'package:ipsc_training/timer_protocol.dart';
import 'package:ipsc_training/timer_session.dart';
import 'package:ipsc_training/training_live.dart';

void main() {
  testWidgets(
    'live shows shots, expands, resets on next timer start and saves only the previous series',
    (tester) async {
      final saved = <List<double>>[];
      final session = TimerSession(
        onImport: (times, _) async {
          saved.add(times);
          return true;
        },
      );
      final link = TimerLink(BluetoothDevice.fromId('00:11:22:33:44:55'));
      link.profile = TimerProtocols.legacyId;
      link.decoder = TimerProtocols.decoder(link.profile);
      session.links[link.device.remoteId.str] = link;
      session.select(link.device.remoteId.str);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: TrainingLive(session: session)),
          ),
        ),
      );
      session.receive(link, [
        0xf8,
        0xf9,
        0x34,
        3,
        0xf9,
        0xf8,
        0xf8,
        0xf9,
        0x36,
        0,
        1,
        20,
        1,
        0,
        0xf9,
        0xf8,
      ]);
      await tester.pumpAndSettle();
      expect(find.text('1.20 с'), findsOneWidget);
      session.receive(link, [0xf8, 0xf9, 0x36, 0, 1, 55, 2, 0, 0xf9, 0xf8]);
      await tester.pumpAndSettle();
      expect(find.text('1.55 с'), findsOneWidget);
      expect(find.text('+0.35'), findsOneWidget);
      await tester.tap(find.byTooltip('На весь экран'));
      await tester.pumpAndSettle();
      expect(find.text('Время, с'), findsOneWidget);
      expect(find.text('Сплит, с'), findsWidgets);
      expect(find.text('1.55'), findsOneWidget);
      session.receive(link, [0xf8, 0xf9, 0x34, 4, 0xf9, 0xf8]);
      await tester.pumpAndSettle();
      expect(find.text('0.00 с'), findsOneWidget);
      expect(find.text('Ожидаем выстрелы'), findsOneWidget);
      expect(saved, [
        [1.2, 1.55],
      ]);
      await tester.tap(find.byTooltip('Вернуться к тренировке'));
      await tester.pumpAndSettle();
      expect(link.active, isNotNull);
      expect(find.text('0.00 с'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'full screen fits narrow portrait and short landscape with large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [const Size(320, 568), const Size(640, 320)]) {
        tester.view.physicalSize = size;
        final session = TimerSession(onImport: (_, _) async => true);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(1.5),
              ),
              child: Scaffold(
                appBar: AppBar(title: const Text('Тренировка')),
                body: TrainingLive(
                  session: session,
                  latest: Run(id: 'x', times: [1.2, 1.55]),
                  fullscreen: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1.55 с'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
