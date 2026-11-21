// flutter run --profile -t tool/whisper_diagnostic.dart -d <device>
// Isolated microphone/native test: no camera, TTS or command execution.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:yolo_live_detection/services/whisper_service.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: DiagnosticPage()));
}

class DiagnosticPage extends StatefulWidget {
  const DiagnosticPage({super.key});
  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> {
  final recorder = PcmCommandRecorder();
  final backend = NativeWhisperBackend();
  final bytes = BytesBuilder(copy: false);
  final clock = Stopwatch();
  StreamSubscription<Uint8List>? subscription;
  Timer? deadline;
  Uint8List? captured;
  String? capturedExpected;
  double? recordingWallMs;
  bool recording = false, busy = false, greedy = false, fullContext = false;
  int threads = 2;
  String expected = 'Начать', status = 'Запишите команду (до 5 секунд).';
  final phrases = ['Начать', 'Остановить', 'Что впереди?', 'Повтори'];

  Future<void> start() async {
    setState(() => busy = true);
    try {
      if (!await recorder.hasPermission()) {
        throw StateError('Нет доступа к микрофону');
      }
      await backend.initialize();
      bytes.clear();
      final stream = await recorder.start();
      clock
        ..reset()
        ..start();
      subscription = stream.listen(
        (data) {
          final available = 160000 - bytes.length;
          if (available > 0) {
            bytes.add(data.sublist(0, data.length.clamp(0, available)));
          }
        },
        onError: (Object error) {
          showError(error);
        },
      );
      setState(() {
        recording = true;
        busy = false;
        status = 'Говорите: $expected';
      });
      deadline = Timer(const Duration(seconds: 5), () => unawaited(stop()));
    } catch (error) {
      showError(error);
    }
  }

  void showError(Object error) {
    if (mounted) {
      setState(() {
        busy = false;
        status = error.toString();
      });
    }
  }

  Future<void> stop() async {
    if (!recording) return;
    setState(() {
      recording = false;
      busy = true;
    });
    deadline?.cancel();
    try {
      await recorder.stop();
      await subscription?.cancel();
      recordingWallMs = clock.elapsedMicroseconds / 1000;
      capturedExpected = expected;
      captured = bytes.takeBytes();
      await recognize(recorded: true);
    } catch (error) {
      showError(error);
    }
  }

  Future<void> recognize({bool recorded = false}) async {
    setState(() => busy = true);
    final watch = Stopwatch()..start();
    try {
      final pcm = captured!;
      final output = Map<String, dynamic>.from(
        await NativeWhisperBackend.channel.invokeMethod('transcribe', {
          'pcm': pcm,
          'diagnostic': true,
          'threads': threads,
          'greedy': greedy,
          'full_context': fullContext,
        }) as Map,
      );
      final text = output['text'] as String;
      final samples = ByteData.sublistView(pcm);
      var peak = 0, clipped = 0;
      double square = 0;
      for (var i = 0; i < pcm.length; i += 2) {
        final v = samples.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
        if (v >= 32767) clipped++;
        square += (v / 32768) * (v / 32768);
      }
      final report = <String, dynamic>{
        ...output,
        'expected': capturedExpected,
        'raw_text': text,
        'command_matched':
            VoiceCommandParser.parse(text) ==
            VoiceCommandParser.parse(capturedExpected!),
        'action_executed': false,
        'camera_active': false,
        'tts_active': false,
        'recording_audio_ms': pcm.length / 32,
        'recording_wall_ms': recordingWallMs,
        'request_wall_ms': watch.elapsedMicroseconds / 1000,
        'total_command_ms': recorded ? clock.elapsedMicroseconds / 1000 : null,
        'peak': peak,
        'mean_square': square / (pcm.length / 2),
        'clipped_samples': clipped,
        'rss_bytes': ProcessInfo.currentRss,
        'replay': !recorded,
      };
      final path = output['wav_path'] as String;
      await File('$path.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      debugPrint('WHISPER DIAGNOSTIC ${jsonEncode(report)}');
      if (mounted) {
        setState(() {
          status = const JsonEncoder.withIndent('  ').convert(report);
          busy = false;
        });
      }
    } catch (error) {
      showError(error);
    }
  }

  @override
  void dispose() {
    deadline?.cancel();
    unawaited(subscription?.cancel());
    unawaited(recorder.dispose());
    unawaited(backend.cancel());
    unawaited(backend.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Whisper: микрофон → сырой текст')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButton<String>(
          value: expected,
          items: phrases
              .map((p) => DropdownMenuItem(value: p, child: Text(p)))
              .toList(),
          onChanged: busy || recording
              ? null
              : (p) => setState(() => expected = p!),
        ),
        DropdownButton<int>(
          value: threads,
          items: [2, 4]
              .map(
                (n) =>
                    DropdownMenuItem(value: n, child: Text('$n CPU threads')),
              )
              .toList(),
          onChanged: busy || recording
              ? null
              : (n) => setState(() => threads = n!),
        ),
        SwitchListTile(
          title: const Text('Greedy (иначе beam=5)'),
          value: greedy,
          onChanged: busy || recording
              ? null
              : (v) => setState(() => greedy = v),
        ),
        SwitchListTile(
          title: const Text('Полный audio context (иначе 512)'),
          value: fullContext,
          onChanged: busy || recording
              ? null
              : (v) => setState(() => fullContext = v),
        ),
        ElevatedButton(
          onPressed: busy
              ? null
              : recording
              ? stop
              : start,
          child: Text(recording ? 'Стоп и распознать' : 'Записать'),
        ),
        ElevatedButton(
          onPressed: busy || recording || captured == null ? null : recognize,
          child: const Text('Повторить на том же аудио'),
        ),
        SelectableText(status),
      ],
    ),
  );
}
