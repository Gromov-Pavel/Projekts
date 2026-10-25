import 'package:flutter/material.dart';

import 'watch_bridge.dart';

class WatchScreen extends StatelessWidget {
  const WatchScreen({super.key, required this.bridge});
  final WatchBridge bridge;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bridge,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Часы')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Часы должны быть подключены к Zepp. Оставьте Zepp работающим на телефоне. Интернет для результатов не нужен.',
          ),
          SwitchListTile(
            title: const Text('Связь с часами'),
            value: bridge.enabled,
            onChanged: bridge.busy
                ? null
                : (value) => value ? bridge.start() : bridge.stop(),
          ),
          Text(bridge.status),
          TextButton(
            onPressed: bridge.busy ? null : bridge.forget,
            child: const Text('Забыть часы'),
          ),
          if (bridge.peer != null && !bridge.approved) ...[
            Text('На часах должен быть код: ${bridge.peerCode ?? "—"}'),
            FilledButton(
              onPressed: bridge.approve,
              child: const Text('Код совпадает — разрешить'),
            ),
            const Text(
              'Разрешайте только после нажатия «Подключить» на своих часах.',
            ),
          ],
          const SizedBox(height: 24),
          ListTile(
            title: const Text('Источник выбирается автоматически'),
            subtitle: Text(
              bridge.phone
                  ? 'Внешний таймер не подключён — таймер телефона'
                  : 'Подключённый внешний таймер',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            bridge.phone
                ? 'После выбора откройте «Тренировка → Таймер телефона» и оставьте экран открытым. На часах появятся «Старт» и «Завершить». Не сворачивайте приложение: микрофон останавливается для защиты от случайной записи.'
                : 'На часы идёт один таймер, выбранный на экране подключения таймера. Его старт, выстрелы и завершение отображаются автоматически. Удалённые команды Special Pie пока не подтверждены — используйте кнопки самого таймера.',
          ),
          const SizedBox(height: 24),
          const Text(
            'Включите связь → на часах нажмите «Подключить» → подтвердите устройство здесь. Подтверждённые часы запоминаются и подключаются автоматически. Повторная сверка нужна после сброса пары.',
          ),
        ],
      ),
    ),
  );
}
