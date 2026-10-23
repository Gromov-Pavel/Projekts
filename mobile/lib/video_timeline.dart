import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shot times and playhead share the video's start-relative time base.
class ShotTimeline extends StatefulWidget {
  const ShotTimeline({
    super.key,
    required this.duration,
    required this.position,
    required this.primaryTimes,
    this.comparisonTimes = const [],
    this.candidates = const [],
    this.comparisonCandidates = const [],
    required this.onSeek,
  });

  final double duration, position;
  final List<double> primaryTimes,
      comparisonTimes,
      candidates,
      comparisonCandidates;
  final ValueChanged<double> onSeek;

  @override
  State<ShotTimeline> createState() => _ShotTimelineState();
}

class _ShotTimelineState extends State<ShotTimeline> {
  final _scroll = ScrollController();
  int _zoom = 1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration.isFinite && widget.duration > 0
        ? widget.duration
        : 1.0;
    final position = widget.position.isFinite
        ? widget.position.clamp(0.0, duration)
        : 0.0;
    final colors = Theme.of(context).colorScheme;
    bool visibleTime(double time) =>
        time.isFinite && time >= 0 && time <= duration;
    final candidates = widget.candidates.where(visibleTime).toList();
    final comparisonCandidates = widget.comparisonCandidates
        .where(visibleTime)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Время от старта, с'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('A · Выстрелы', style: TextStyle(color: Colors.teal.shade700)),
            Text(
              'B · Выстрелы',
              style: TextStyle(color: Colors.brown.shade700),
            ),
            if (candidates.isNotEmpty || comparisonCandidates.isNotEmpty)
              const Text('? · Кандидаты'),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('×1')),
                ButtonSegment(value: 2, label: Text('×2')),
                ButtonSegment(value: 4, label: Text('×4')),
              ],
              selected: {_zoom},
              onSelectionChanged: (value) =>
                  setState(() => _zoom = value.single),
              showSelectedIcon: false,
              style: const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(48, 48)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth * _zoom;
            return Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              interactive: true,
              scrollbarOrientation: ScrollbarOrientation.bottom,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Semantics(
                  label:
                      'Дорожка A: ${widget.primaryTimes.length} выстрелов. '
                      'Дорожка B: ${widget.comparisonTimes.length} выстрелов. '
                      'Кандидаты A (?): ${candidates.length}. '
                      'Кандидаты B (?): ${comparisonCandidates.length}. '
                      'Старт: 0 секунд.',
                  child: GestureDetector(
                    key: const ValueKey('shot-timeline-track'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => widget.onSeek(
                      ((details.localPosition.dx - 12) /
                              (width - 24) *
                              duration)
                          .clamp(0.0, duration),
                    ),
                    child: CustomPaint(
                      size: Size(width, 160),
                      painter: _TimelinePainter(
                        duration: duration,
                        position: position,
                        primary: widget.primaryTimes,
                        comparison: widget.comparisonTimes,
                        candidates: candidates,
                        comparisonCandidates: comparisonCandidates,
                        colors: colors,
                        textDirection: Directionality.of(context),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        Semantics(
          label: 'Позиция видео от старта',
          child: Slider(
            value: position,
            max: duration,
            label: '${position.toStringAsFixed(2)} с',
            semanticFormatterCallback: (value) =>
                '${value.toStringAsFixed(2)} секунд',
            onChanged: widget.onSeek,
          ),
        ),
        Text('Позиция: ${position.toStringAsFixed(2)} с · Старт: 0 с'),
      ],
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.duration,
    required this.position,
    required this.primary,
    required this.comparison,
    required this.candidates,
    required this.comparisonCandidates,
    required this.colors,
    required this.textDirection,
  });

  final double duration, position;
  final List<double> primary, comparison, candidates, comparisonCandidates;
  final ColorScheme colors;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 12.0, top = 26.0, lane = 56.0;
    final width = math.max(1.0, size.width - 24);
    double x(double time) => left + time / duration * width;
    void text(
      String label,
      Offset offset,
      Color color, {
      double fontSize = 11,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: fontSize, color: color),
        ),
        textDirection: textDirection,
      )..layout();
      painter.paint(canvas, offset);
    }

    canvas.drawRect(
      Rect.fromLTWH(0, top, size.width, lane),
      Paint()..color = colors.surfaceContainerHigh,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, top + lane, size.width, lane),
      Paint()..color = colors.surfaceContainerLow,
    );
    final tickStep = math.max(1, (duration / math.max(1, width / 60)).ceil());
    for (var second = 0; second <= duration; second += tickStep) {
      final tickX = x(second.toDouble());
      canvas.drawLine(
        Offset(tickX, top - 5),
        Offset(tickX, top + lane * 2),
        Paint()
          ..color = colors.outlineVariant
          ..strokeWidth = 1,
      );
      text('$second', Offset(tickX - 3, 4), colors.onSurface);
    }
    void shots(List<double> times, double y, Color color) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 3;
      for (final time in times) {
        if (!time.isFinite || time < 0 || time > duration) continue;
        canvas.drawLine(
          Offset(x(time), y + 8),
          Offset(x(time), y + lane - 8),
          paint,
        );
      }
    }

    shots(primary, top, Colors.teal.shade700);
    shots(comparison, top + lane, Colors.amber.shade800);
    void candidateMarks(List<double> times, double laneTop) {
      for (final time in times) {
        if (!time.isFinite || time < 0 || time > duration) continue;
        final candidateX = x(time);
        for (var y = laneTop + 18; y < laneTop + lane - 6; y += 8) {
          canvas.drawLine(
            Offset(candidateX, y),
            Offset(candidateX, y + 4),
            Paint()
              ..color = colors.outline
              ..strokeWidth = 2,
          );
        }
        text('?', Offset(candidateX - 3, laneTop + 1), colors.onSurface);
      }
    }

    candidateMarks(candidates, top);
    candidateMarks(comparisonCandidates, top + lane);
    final playheadX = x(position);
    canvas.drawLine(
      Offset(playheadX, top - 6),
      Offset(playheadX, top + lane * 2),
      Paint()
        ..color = colors.surface
        ..strokeWidth = 6,
    );
    canvas.drawLine(
      Offset(playheadX, top - 6),
      Offset(playheadX, top + lane * 2),
      Paint()
        ..color = colors.onSurface
        ..strokeWidth = 3,
    );
    text('A', const Offset(2, top + 20), colors.onSurface);
    text('B', const Offset(2, top + lane + 20), colors.onSurface);
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) => true;
}
