// Runs the production detector on a private corpus; no audio or identities are copied.
import 'dart:convert';
import 'dart:io';

import '../mobile/lib/video_analysis.dart';

void main(List<String> args) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
      'Usage: dart research/evaluate_audio.dart FEATURES OUTPUT.json [SPLIT]',
    );
    exitCode = 64;
    return;
  }
  final output = <Map<String, dynamic>>[];
  final paths =
      Directory(args[0])
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final path in paths) {
    final data = jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
    final summary = data['summary'] as Map<String, dynamic>;
    if (args.length == 3 && summary['split'] != args[2]) continue;
    final frames = (data['frames'] as List)
        .map(
          (dynamic r) => AudioFrame(
            (r[0] as num).toDouble(),
            (r[1] as num).toDouble(),
            (r[2] as num).toDouble(),
            (r[3] as num).toDouble(),
          ),
        )
        .toList();
    final result = analyzeAudio(frames);
    output.add({
      'id': summary['id'],
      'group': summary['group'],
      'split': summary['split'],
      'duration': summary['duration'],
      'beep': result.beep,
      'beeps': [
        for (final c in result.candidates)
          {
            'time': c.time,
            'duration': c.duration,
            'frequency': c.frequencyHz,
            'score': c.confidence,
            'boundary': c.atBoundary,
          },
      ],
      'shotCandidates': result.shotCandidates,
      'shotsAfterProposal': result.shotCandidates
          .where((t) => result.beep != null && t > result.beep!)
          .length,
    });
  }
  File(args[1]).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schema': 1,
      'limitation': 'Unlabelled proposals, not precision/recall or ground truth. Native decoding must be qualified separately.',
      'items': output,
    }),
  );
  stdout.writeln(
    jsonEncode({
      'files': output.length,
      'beepProposals': output.where((x) => x['beep'] != null).length,
      'missingOrClipped': output.where((x) => x['beep'] == null).length,
    }),
  );
}
