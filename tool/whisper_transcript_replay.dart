import 'dart:convert';
import 'dart:io';

import 'package:yolo_live_detection/services/voice_command_parser.dart';

void main() {
  final data = jsonDecode(
    File('docs/whisper_android_validation.json').readAsStringSync(),
  ) as Map;
  var correct = 0, decoded = 0, correctDecoded = 0;
  final byClass = <String, List<int>>{};
  for (final row in data['command'] as List) {
    final matched =
        VoiceCommandParser.parse(row['text'] as String? ?? '').name ==
        row['expected'];
    row['current_parser_matches'] = matched;
    row['routed_command'] = VoiceCommandParser.parse(
      row['text'] as String? ?? '',
    ).name;
    if (matched) correct++;
    if (row['inference_ms'] != null) {
      decoded++;
      if (matched) correctDecoded++;
    }
    final counts = byClass.putIfAbsent(row['expected'] as String, () => [0, 0]);
    counts[1]++;
    if (matched) counts[0]++;
  }
  data['parser_replay'] = {
    'correct': correct,
    'total': (data['command'] as List).length,
    'decoded': decoded,
    'correct_decoded': correctDecoded,
    'by_class': byClass,
    'scope': 'Current pure Dart parser applied to native Android transcripts; not live UI execution',
  };
  File(
    'docs/whisper_android_validation.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(data)}\n');
  stdout.writeln(jsonEncode(data['parser_replay']));
}
