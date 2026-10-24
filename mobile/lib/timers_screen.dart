import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'timer_protocol.dart';
import 'timer_session.dart';
import 'training_live.dart';
export 'timer_session.dart' show timerErrorMessage;

class TimersScreen extends StatelessWidget {
  const TimersScreen({super.key, required this.session});
  final TimerSession session;

  Future<bool> _confirmLegacy(BuildContext context, TimerLink link) async {
    if (link.acceptedLegacy) return true;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Приём Special Pie'),
        content: const Text(
          'Используется экспериментальный старый формат Special Pie. Сверьте времена с экраном таймера. Завершённые серии автоматически сохраняются в тренировках без упражнения.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Начать приём'),
          ),
        ],
      ),
    );
    if (accepted != true) return false;
    link.acceptedLegacy = true;
    link.profile = TimerProtocols.legacyId;
    return true;
  }

  Future<void> _start(BuildContext context, TimerLink link) async {
    final c = session.legacyCharacteristic(link);
    if (c == null) {
      session.showMessage(
        'Канал Special Pie не обнаружен. Откройте технические подробности.',
      );
      return;
    }
    if (await _confirmLegacy(context, link)) await session.subscribe(link, c);
  }

  Widget _device(BuildContext context, TimerLink link) {
    final chars = link.services
        .expand((s) => s.characteristics)
        .where((c) => c.properties.notify || c.properties.indicate)
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              title: Text(
                session.preferences.timers[link.device.remoteId.str]?.name ??
                    (link.device.platformName.isEmpty
                        ? 'Таймер'
                        : link.device.platformName),
              ),
              subtitle: Text(link.status),
              onTap: () => session.select(link.device.remoteId.str),
              trailing: Icon(
                link.device.isConnected
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
              ),
            ),
            if (session.preferences.timers.containsKey(
              link.device.remoteId.str,
            ))
              SwitchListTile(
                title: const Text('Подключаться автоматически'),
                value: session
                    .preferences
                    .timers[link.device.remoteId.str]!
                    .autoConnect,
                onChanged: (value) =>
                    session.setAutoConnect(link.device.remoteId.str, value),
              ),
            if (link.device.isConnected && link.notifications == null)
              FilledButton(
                onPressed: session.busy ? null : () => _start(context, link),
                child: const Text('Определить протокол и начать приём'),
              ),
            TextButton(
              onPressed: session.busy
                  ? null
                  : () => link.device.isConnected
                        ? session.disconnect(link)
                        : session.connect(link.device),
              child: Text(
                link.device.isConnected ? 'Отключить' : 'Подключить снова',
              ),
            ),
            for (final series in link.pending.where(
              (s) => s.times.isNotEmpty && !s.saved && s.complete,
            ))
              ListTile(
                title: Text('Серия: ${series.times.length} выстрелов'),
                subtitle: Text(
                  series.partial ? 'Неполная серия' : 'Ожидает сохранения',
                ),
                trailing: TextButton(
                  onPressed: series.saving
                      ? null
                      : () => session.saveSeries(series),
                  child: const Text('Повторить сохранение'),
                ),
              ),
            ExpansionTile(
              title: const Text('Технические подробности'),
              children: [
                SelectableText(link.device.remoteId.str),
                DropdownButton<String>(
                  isExpanded: true,
                  value: link.profile,
                  items: TimerProtocols.profiles
                      .map(
                        (p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.label, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: link.notifications != null
                      ? null
                      : (value) async {
                          if (value == null) return;
                          if (value == TimerProtocols.legacyId &&
                              !await _confirmLegacy(context, link)) {
                            return;
                          }
                          link.profile = value;
                          session.select(link.device.remoteId.str);
                        },
                ),
                for (final c in chars.where(
                  (c) =>
                      link.profile == TimerProtocols.rawId ||
                      (c.serviceUuid == Guid('fff0') && c.uuid == Guid('fff1')),
                ))
                  TextButton(
                    onPressed:
                        !link.device.isConnected || link.notifications != null
                        ? null
                        : () async {
                            if (link.profile == TimerProtocols.legacyId &&
                                !await _confirmLegacy(context, link)) {
                              return;
                            }
                            await session.subscribe(link, c);
                          },
                    child: Text('Слушать ${c.serviceUuid.str} / ${c.uuid.str}'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Подключение таймера')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (session.selected != null) TrainingLive(session: session),
            if (session.links.length > 1)
              DropdownButton<String>(
                isExpanded: true,
                value: session.selectedId,
                items: session.links.values
                    .map(
                      (link) => DropdownMenuItem(
                        value: link.device.remoteId.str,
                        child: Text(
                          '${link.device.platformName} · ${link.device.remoteId.str}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (id) {
                  if (id != null) session.select(id);
                },
              ),
            Text(session.backgroundStatus),
            if (session.connectedCount > 0 && !session.serviceRunning)
              TextButton(
                onPressed: session.refreshBackgroundService,
                child: const Text('Повторить запуск фонового приёма'),
              ),
            const Text(
              'Протокол определяется по данным таймера. Сохранённые таймеры подключаются автоматически, если это включено. После ручного отключения автоподключение приостанавливается до следующего запуска приложения.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: session.busy || session.scanning ? null : session.scan,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(session.scanning ? 'Идёт поиск…' : 'Найти таймер'),
            ),
            if (session.scanning) const LinearProgressIndicator(),
            if (session.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(session.message),
              ),
            if (session.searched && !session.scanning && session.found.isEmpty)
              const Text(
                'Таймер не найден. Проверьте Bluetooth и отключите его от другого приложения.',
              ),
            if (session.links.isNotEmpty)
              const Text(
                'Мои таймеры',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            for (final timer in session.preferences.ordered)
              if (session.links[timer.id] != null)
                _device(context, session.links[timer.id]!),
            for (final link in session.links.values.where(
              (link) => !session.preferences.timers.containsKey(
                link.device.remoteId.str,
              ),
            ))
              _device(context, link),
            if (session.found.any(
              (r) => !session.links.containsKey(r.device.remoteId.str),
            ))
              const Text(
                'Найденные устройства',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            for (final result in session.found.where(
              (r) => !session.links.containsKey(r.device.remoteId.str),
            ))
              ListTile(
                title: Text(
                  result.device.platformName.isEmpty
                      ? 'Устройство без имени — проверьте свой таймер'
                      : result.device.platformName,
                ),
                subtitle: Text(result.device.remoteId.str),
                trailing: TextButton(
                  onPressed: session.busy || session.connectedCount >= 5
                      ? null
                      : () => session.connect(result.device),
                  child: const Text('Подключить'),
                ),
              ),
            ExpansionTile(
              title: const Text('Диагностика'),
              children: [
                Text(
                  'Соединений ${session.connectedCount}/5 · ${(session.diagnosticBytes / 1024).round()} КБ${session.full ? " · журнал заполнен" : ""}',
                ),
                if (session.lastError != null)
                  SelectableText(session.lastError!),
                TextButton(
                  onPressed: session.exportDiagnostics,
                  child: const Text('Экспорт JSON'),
                ),
                const Text(
                  'Сырые данные хранятся до закрытия приложения. Процесс может быть остановлен системой; восстановление Bluetooth после этого не гарантируется.',
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
