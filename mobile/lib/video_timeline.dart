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
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                      'Кандидаты A: ${candidates.length}. '
                      'Кандидаты B: ${comparisonCandidates.length}. '
                      'Старт: 0 секунд.',
                  child: GestureDetector(
                    key: const ValueKey('shot-timeline-track'),
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) => widget.onSeek(
                      ((details.localPosition.dx - 24) /
                              (width - 36) *
                              duration)
                          .clamp(0.0, duration),
                    ),
                    child: CustomPaint(
                      size: Size(width, 58),
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
        SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: Semantics(
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
              ),
              PopupMenuButton<int>(
                tooltip: 'Масштаб дорожки',
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('×$_zoom'),
                ),
                itemBuilder: (_) => [
                  for (final zoom in [1, 2, 4])
                    PopupMenuItem(value: zoom, child: Text('×$zoom')),
                ],
                onSelected: (zoom) => setState(() => _zoom = zoom),
              ),
            ],
          ),
        ),
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
    const left = 24.0, top = 18.0, lane = 16.0;
    final width = math.max(1.0, size.width - 36);
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
        ..strokeWidth = 1.5;
      for (final time in times) {
        if (!time.isFinite || time < 0 || time > duration) continue;
        canvas.drawLine(
          Offset(x(time), y + 2),
          Offset(x(time), y + lane - 2),
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
        for (var y = laneTop + 2; y < laneTop + lane - 2; y += 5) {
          canvas.drawLine(
            Offset(candidateX, y),
            Offset(candidateX, y + 3),
            Paint()
              ..color = colors.outline
              ..strokeWidth = 2,
          );
        }
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
    text('A', const Offset(2, top + 1), colors.onSurface);
    text('B', const Offset(2, top + lane + 1), colors.onSurface);
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) => true;
}
