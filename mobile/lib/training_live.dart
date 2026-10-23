import 'package:flutter/material.dart';

import 'domain.dart';
import 'timer_session.dart';

/// The same live series stays visible on the range and in full screen.
class TrainingLive extends StatelessWidget {
  const TrainingLive({
    super.key,
    required this.session,
    this.latest,
    this.fullscreen = false,
  });

  final TimerSession session;
  final Run? latest;
  final bool fullscreen;

  void _expand(BuildContext context) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('Тренировка'),
          leading: IconButton(
            tooltip: 'Вернуться к тренировке',
            icon: const Icon(Icons.fullscreen_exit),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: SafeArea(
          child: TrainingLive(
            session: session,
            latest: latest,
            fullscreen: true,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final link = session.selected;
      final series = link?.active ?? link?.pending.lastOrNull;
      final times = link == null
          ? latest?.times ?? <double>[]
          : series?.times ?? <double>[];
      final total = link == null && latest != null
          ? latest!.totalTime
          : times.lastOrNull ?? 0.0;
      final connected = link?.device.isConnected ?? false;
      final name = link == null
          ? 'Тренировка'
          : link.device.platformName.isEmpty
          ? 'Внешний таймер'
          : link.device.platformName;
      final status = link == null
          ? latest == null
                ? 'Подключите таймер или запишите проход'
                : 'Последний сохранённый проход'
          : !connected
          ? 'Соединение потеряно · подключите таймер снова'
          : link.notifications == null
          ? 'Подключён · включите приём в настройках таймера'
          : link.active != null
          ? 'Приём выстрелов · новая серия начнётся с нуля'
          : 'Готов к новой серии · приём продолжается';
      final split = times.isEmpty
          ? 0.0
          : times.length == 1
          ? times.first
          : times.last - times[times.length - 2];
      final textTheme = Theme.of(context).textTheme;
      final color = Theme.of(context).colorScheme;
      final header = Row(
        children: [
          Icon(
            link == null
                ? Icons.timer_outlined
                : connected
                ? Icons.bluetooth_connected
                : Icons.bluetooth_disabled,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: textTheme.titleMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!fullscreen)
            IconButton(
              tooltip: 'На весь экран',
              onPressed: () => _expand(context),
              icon: const Icon(Icons.fullscreen),
            ),
        ],
      );
      final number = Semantics(
        liveRegion: true,
        label:
            'Последнее время ${total.toStringAsFixed(2)} секунды, выстрелов ${times.length}',
        excludeSemantics: true,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${total.toStringAsFixed(2)} с',
            style: TextStyle(
              fontSize: fullscreen ? 220 : 96,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: color.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
      Widget metric(String label, String value) => Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              child: Text(
                value,
                style: textTheme.headlineSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Text(
              label,
              style: textTheme.labelMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
      final metrics = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          metric('Выстрелов', '${times.length}'),
          metric('Первый, с', (times.firstOrNull ?? 0).toStringAsFixed(2)),
          metric('Сплит, с', split.toStringAsFixed(2)),
        ],
      );
      final finish = link?.active == null
          ? null
          : FilledButton.tonal(
              onPressed: times.isEmpty
                  ? null
                  : () => session.finishSeries(link!),
              child: const Text('Завершить серию'),
            );
      final saved = series == null
          ? null
          : Text(
              series.saving
                  ? 'Сохраняем…'
                  : series.saved
                  ? 'Серия сохранена'
                  : series.complete
                  ? 'Не сохранена · повторите в настройках таймера'
                  : 'Сохранится по завершении серии',
              style: textTheme.labelMedium,
            );
      final table = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: Row(
              children: [
                SizedBox(width: 48, child: Text('№')),
                Expanded(child: Text('Время, с')),
                Expanded(child: Text('Сплит, с', textAlign: TextAlign.end)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: times.isEmpty
                ? const Center(
                    child: Text(
                      'Ожидаем выстрелы',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: times.length,
                    itemBuilder: (context, index) {
                      final i = times.length - 1 - index;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 12,
                        ),
                        child: Row(
                          children: [
                            SizedBox(width: 48, child: Text('${i + 1}')),
                            Expanded(
                              child: Text(
                                times[i].toStringAsFixed(2),
                                style: textTheme.titleLarge,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                (i == 0 ? times[i] : times[i] - times[i - 1])
                                    .toStringAsFixed(2),
                                textAlign: TextAlign.end,
                                style: textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
      if (fullscreen) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(
                status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, size) {
                    final readout = Column(
                      children: [
                        Expanded(child: Center(child: number)),
                        metrics,
                      ],
                    );
                    return size.maxWidth >= 600
                        ? Row(
                            children: [
                              Expanded(child: readout),
                              const VerticalDivider(width: 24),
                              Expanded(child: table),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(flex: 3, child: readout),
                              const SizedBox(height: 8),
                              Expanded(flex: 2, child: table),
                            ],
                          );
                  },
                ),
              ),
              ?saved,
              ?finish,
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Text(status, style: textTheme.bodySmall),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: number),
            const SizedBox(height: 8),
            metrics,
            if (times.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Выстрел · время / сплит, с', style: textTheme.labelMedium),
              SizedBox(
                height: 74 * MediaQuery.textScalerOf(context).scale(1),
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: times.length,
                  itemBuilder: (context, index) {
                    final i = times.length - 1 - index;
                    return Container(
                      width: 104,
                      margin: const EdgeInsets.only(right: 8, top: 4),
                      padding: const EdgeInsets.all(8),
                      color: color.surfaceContainerLow,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '№${i + 1} · ${times[i].toStringAsFixed(2)}',
                            style: textTheme.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '+${(i == 0 ? times[i] : times[i] - times[i - 1]).toStringAsFixed(2)}',
                              style: textTheme.titleLarge,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            if (saved != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: saved),
            ?finish,
          ],
        ),
      );
    },
  );
}
