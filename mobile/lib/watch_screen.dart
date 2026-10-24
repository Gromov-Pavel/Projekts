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
          DropdownButtonFormField<bool>(
            initialValue: bridge.phone,
            decoration: const InputDecoration(labelText: 'Источник для часов'),
            items: const [
              DropdownMenuItem(value: false, child: Text('Внешний таймер')),
              DropdownMenuItem(value: true, child: Text('Таймер телефона')),
            ],
            onChanged:
                bridge.phase == WatchPhase.running ||
                    bridge.phase == WatchPhase.preparing
                ? null
                : (value) {
                    if (value != null) bridge.selectPhone(value);
                  },
          ),
          const SizedBox(height: 12),
          Text(
            bridge.phone
                ? 'После выбора откройте «Тренировка → Таймер телефона» и оставьте экран открытым. На часах появятся «Старт» и «Завершить». Не сворачивайте приложение: микрофон останавливается для защиты от случайной записи.'
                : 'На часы идёт один таймер, выбранный на экране подключения таймера. Его старт, выстрелы и завершение отображаются автоматически. Удалённые команды Special Pie пока не подтверждены — используйте кнопки самого таймера.',
          ),
          const SizedBox(height: 24),
          const Text(
            'Включите связь → на часах нажмите «Подключить» → подтвердите устройство здесь. После разрыва подтверждение нужно повторить.',
          ),
        ],
      ),
    ),
  );
}
