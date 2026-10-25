import 'package:flutter/material.dart';

/// Keeps one time field per shot; the parent retains validation and saving.
class ShotTimesEditor extends StatefulWidget {
  const ShotTimesEditor({super.key, required this.controller});
  final TextEditingController controller;
  @override
  State<ShotTimesEditor> createState() => _ShotTimesEditorState();
}

class _ShotTimesEditorState extends State<ShotTimesEditor> {
  late final fields = widget.controller.text.trim().isEmpty
      ? <TextEditingController>[]
      : widget.controller.text
            .trim()
            .split(RegExp(r'\s+'))
            .map((s) => TextEditingController(text: s))
            .toList();
  void publish() {
    widget.controller.text = fields.map((f) => f.text.trim()).join(' ');
    setState(() {});
  }

  double? time(int i) =>
      i < 0 ? 0 : double.tryParse(fields[i].text.replaceAll(',', '.'));
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      const Text('Время выстрелов'),
      LayoutBuilder(
        builder: (context, box) {
          final columns = (box.maxWidth / 132).floor().clamp(1, 10);
          final width = (box.maxWidth - (columns - 1) * 8) / columns;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < fields.length; i++)
                SizedBox(
                  width: width,
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          Text('№${i + 1}'),
                          TextField(
                            key: ValueKey('shot-time-$i'),
                            controller: fields[i],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Время, с',
                            ),
                            onChanged: (_) => publish(),
                          ),
                          Text(
                            'Сплит: ${time(i) != null && time(i - 1) != null ? (time(i)! - time(i - 1)!).toStringAsFixed(2) : '—'}',
                          ),
                          IconButton(
                            tooltip: 'Удалить выстрел ${i + 1}',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () {
                              final removed = fields.removeAt(i);
                              publish();
                              // A focused field must detach before its controller is disposed.
                              WidgetsBinding.instance.addPostFrameCallback(
                                (_) => removed.dispose(),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      OutlinedButton.icon(
        icon: const Icon(Icons.add),
        label: const Text('Добавить выстрел'),
        onPressed: () => setState(() => fields.add(TextEditingController())),
      ),
    ],
  );
  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }
}
