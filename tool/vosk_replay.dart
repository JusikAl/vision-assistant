// Device-only engineering replay. Fixtures are explicitly labelled, never live trials.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yolo_live_detection/services/voice_command_router.dart';

const channel = MethodChannel('navigation/vosk');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Vosk: повтор записей…'))),
    ),
  );
  final rows = <Map<String, dynamic>>[];
  try {
    final info = await channel.invokeMapMethod<String, dynamic>('initialize');
    final manifest = jsonDecode(
      await File(
        '/storage/emulated/0/Android/data/com.example.camera/files/vosk72-fixtures/manifest.json',
      ).readAsString(),
    ) as List;
    var session = 0;
    // Evaluate frozen v2 before using v1 for a grammar comparison.
    for (final grammar in ['v2-context-guards', 'v1-commands']) {
      for (final fixture in manifest) {
        final pcm = await File(fixture['path'] as String).readAsBytes();
        for (final endpoint in <double?>[null, 0.5, 0.9, 1.2]) {
          final report = (await channel.invokeMapMethod<String, dynamic>(
            'replay',
            {'pcm': pcm, 'grammar_id': grammar, 'endpoint_end_s': endpoint},
          ))!;
          final raw = jsonDecode(report['raw'] as String) as Map;
          final router = VoiceCommandRouter()..begin(++session);
          final intent = router.route(
            raw['text'] as String,
            session: session,
            isFinal: true,
            alternatives: (raw['alternatives'] as List).map(
              (value) => (value as Map)['text'] as String,
            ),
          );
          rows.add({
            ...report,
            'fixture': fixture,
            'intent': intent.name,
            'raw_text': raw['text'],
            'action_executed': false,
          });
          await channel.invokeMethod('saveReport', {
            'name': 'vosk-recognition-fix-replay.json',
            'json': jsonEncode({'configuration': info, 'rows': rows}),
          });
        }
      }
    }
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Повтор завершён: ${rows.length} проб.')),
        ),
      ),
    );
  } catch (error) {
    await channel.invokeMethod('saveReport', {
      'name': 'vosk-recognition-fix-replay.json',
      'json': jsonEncode({'error': error.toString(), 'rows': rows}),
    });
    runApp(
      MaterialApp(
        home: Scaffold(body: Center(child: Text(error.toString()))),
      ),
    );
  }
}
