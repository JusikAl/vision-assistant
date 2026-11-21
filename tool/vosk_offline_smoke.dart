// Human acceptance runner (no synthetic speech):
// flutter run --release -t tool/vosk_offline_smoke.dart --dart-define=OFFLINE_ONLY=true
//   --dart-define=VOSK_ACTIONS_ENABLED=true --dart-define=VOSK_DIAGNOSTICS_ENABLED=true -d <device>
// Throughput comparison: add --dart-define=VOSK_PERF_ONLY=true (keep room quiet).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yolo_live_detection/app_config.dart';
import 'package:yolo_live_detection/live_camera_page.dart';
import 'package:yolo_live_detection/services/vosk_service.dart';
import 'package:yolo_live_detection/services/voice_command_router.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

void emit(String type, Object data) =>
    debugPrint('VOSK TEST $type ${jsonEncode(data)}');
Future<void> waitFor(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 60)) {
      throw TimeoutException('Device not ready');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('OFFLINE_ONLY')) {
    throw StateError('Offline acceptance only');
  }
  await AppConfig.load();
  runApp(const MaterialApp(home: AcceptanceRunner()));
}

class AcceptanceRunner extends StatefulWidget {
  const AcceptanceRunner({super.key});
  @override
  State<AcceptanceRunner> createState() => _AcceptanceRunnerState();
}

class _AcceptanceRunnerState extends State<AcceptanceRunner> {
  final cameraKey = GlobalKey();
  final rows = <Map<String, dynamic>>[];
  int trial = 0;
  bool busy = false, silenceBatch = false, prepared = false;
  final runId = DateTime.now().toUtc().toIso8601String();
  String status = 'Подготовка…';
  static const commands = [
    'Начать',
    'Закончить',
    'Что впереди?',
    'Опиши окружение',
  ];
  static const negatives = [
    'Какая сегодня погода',
    'Не начинай',
    'Не останавливай',
    'Привет',
    'Как начать работу',
    'Я иду домой',
    'Поставь музыку',
    'Сколько времени',
    'Позвони другу',
    'Открой дверь',
    'Не надо начинать',
    'Что сегодня на обед',
    'Я сказал не стоп',
    'Это начало фильма',
    'Закончили разговор',
    'Впереди выходной',
    'Вокруг тихо',
    'Окружение изменилось',
    'Обстановка хорошая',
    'Спасибо',
  ];
  String get expected => trial < 40
      ? commands[(trial ~/ 10)]
      : trial < 60
      ? negatives[trial - 40]
      : '(тишина)';
  dynamic get camera => cameraKey.currentState;
  VoskService get voice => camera.diagnosticVosk as VoskService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await waitFor(
        () => camera != null && camera.controller?.value.isInitialized == true,
      );
      await voice.initialize();
      final previous = voice.onStateChanged;
      voice.onStateChanged = (value) {
        previous?.call(value);
        if (mounted) {
          setState(
            () => status = value == VoskState.listening
                ? 'Слушаю: $expected'
                : value == VoskState.processing
                ? 'Распознаю'
                : 'Ожидание / выполнение команды',
          );
        }
      };
      prepared = true;
      if (const bool.fromEnvironment('VOSK_PERF_ONLY')) {
        unawaited(benchmark());
      } else if (mounted) {
        setState(
          () => status =
              'Нажмите «Проба», дождитесь «Слушаю», произнесите фразу.',
        );
      }
    });
  }

  Future<void> attempt() async {
    if (busy || trial >= 80) return;
    setState(() => busy = true);
    final phrase = expected;
    try {
      // First half with camera fully closed; second half with YOLO/Safety running.
      final active = trial < 40 ? trial % 10 >= 5 : trial.isOdd;
      if (active && camera.running != true) await camera.startDetection();
      if (!active) await camera.suspendCameraForDiagnostic();
      await waitFor(
        () => !voice.isSpeaking && camera.processingVoiceCommand != true,
      );
      final before = voice.lastMeasurement;
      final beforeAction = camera.lastVoiceAction;
      final watch = Stopwatch()..start();
      await camera.activateVoiceCommand();
      final measurement = voice.lastMeasurement;
      final raw = identical(before, measurement) ? null : measurement;
      final action = identical(beforeAction, camera.lastVoiceAction)
          ? null
          : camera.lastVoiceAction as Map<String, dynamic>?;
      final expectedCommand =
          VoiceCommandRouter.phrases[VoiceCommandParser.normalize(phrase)] ??
          VoiceCommand.unknown;
      final actualCommand = action?['command'];
      final valid = raw != null && voice.lastError == null;
      final fullPhraseConfirmed = phrase == 'Опиши окружение' && mounted
          ? await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => AlertDialog(
                    title: const Text('Подтверждение произнесённой фразы'),
                    content: const Text(
                      'В этой попытке вы произнесли полностью «Опиши окружение», включая второе слово?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Нет'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Да, полностью'),
                      ),
                    ],
                  ),
                ) ??
                false
          : null;
      final executed = action?['executed'] == true;
      final intentOnly = action?['intent_only'] == true;
      final expectedState = switch (expectedCommand) {
        VoiceCommand.start => executed && camera.running == true,
        VoiceCommand.stop => executed && camera.running == false,
        VoiceCommand.describeEnvironment =>
          intentOnly && fullPhraseConfirmed == true,
        _ => executed,
      };
      final actionSuccess =
          valid &&
          (trial < 40
              ? actualCommand == expectedCommand.name && expectedState
              : actualCommand == null ||
                    actualCommand == VoiceCommand.unknown.name);
      final row = <String, dynamic>{
        'run_id': runId,
        'suite': 'TZ7.2',
        'build_mode': const bool.fromEnvironment('dart.vm.product')
            ? 'release'
            : 'non_release',
        'valid_measurement': valid,
        'spoken_full_phrase_confirmed': fullPhraseConfirmed,
        'action': action,
        'success': actionSuccess,
        'trial': trial + 1,
        'expected': phrase,
        'kind': trial < 40
            ? 'command'
            : trial < 60
            ? 'negative'
            : 'silence',
        'detector_active_before': active,
        'camera_preview_before': active,
        'running_after': camera.running,
        'reply': camera.lastVoiceReply,
        'wall_including_action_tts_ms': watch.elapsedMicroseconds / 1000,
        'measurement': raw,
        'error':
            voice.lastError ??
            (valid
                ? null
                : 'No final result; cancelled or interrupted session'),
        'rss_bytes': ProcessInfo.currentRss,
      };
      rows.add(row);
      emit('human_trial', row);
      const persistence = MethodChannel('navigation/vosk');
      await persistence.invokeMethod('saveReport', {
        'name': 'vosk-recognition-fix-trials.json',
        'json': const JsonEncoder.withIndent('  ').convert(rows),
      });
      if (mounted) {
        setState(() {
          trial++;
          busy = false;
          status =
              'Vosk: ${raw?['raw_text'] ?? '(нет текста)'}; '
              '${actionSuccess ? 'успех' : 'ошибка'}';
        });
      }
    } catch (error) {
      emit('error', error.toString());
      if (mounted) {
        setState(() {
          status = error.toString();
          busy = false;
        });
      }
    }
  }

  Future<void> benchmark() async {
    try {
      // Two balanced passes with identical windows and two bounded PTT sessions.
      for (final condition in [
        (false, false),
        (false, true),
        (true, false),
        (true, true),
        (true, true),
        (true, false),
        (false, true),
        (false, false),
      ]) {
        final (cameraActive, active) = condition;
        if (cameraActive) {
          await camera.startDetection();
          await waitFor(() => camera.lastResult != null);
        } else {
          await camera.suspendCameraForDiagnostic();
        }
        await waitFor(() => !voice.isSpeaking);
        var finished = false, attempts = 0;
        var dutyMs = 0;
        Future<void> microphoneLoad() async {
          for (var i = 0; i < 2 && !finished; i++) {
            final watch = Stopwatch()..start();
            try {
              await voice.startListening();
            } catch (_) {}
            dutyMs += watch.elapsedMilliseconds;
            attempts++;
            if (i == 0 && !finished) {
              await Future<void>.delayed(const Duration(seconds: 4));
            }
          }
        }

        final before = await const MethodChannel('navigation/performance')
            .invokeMapMethod<String, dynamic>('snapshot');
        final job = active ? microphoneLoad() : Future<void>.value();
        final latencies = <double>[];
        DateTime? previous = camera.lastResult as DateTime?;
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 20)) {
          final current = camera.lastResult as DateTime?;
          if (current != null && current != previous) {
            previous = current;
            latencies.add(camera.cameraToResultMs as double);
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final elapsed = watch.elapsedMilliseconds;
        final after = await const MethodChannel('navigation/performance')
            .invokeMapMethod<String, dynamic>('snapshot');
        finished = true;
        await voice.cancel();
        await job;
        latencies.sort();
        final row = <String, dynamic>{
          'vosk_active': active,
          'camera_active': cameraActive,
          'ptt_sessions_planned': active ? 2 : 0,
          'window_ms': elapsed,
          'results': latencies.length,
          'results_per_second': latencies.length * 1000 / elapsed,
          'camera_p50_ms': latencies.isEmpty
              ? null
              : latencies[latencies.length ~/ 2],
          'camera_p95_ms': latencies.isEmpty
              ? null
              : latencies[((latencies.length - 1) * .95).ceil()],
          'rss_bytes': ProcessInfo.currentRss,
          'microphone_attempts': attempts,
          'microphone_job_ms': dutyMs,
          'cpu_ms':
              (after?['cpu_ms'] as num? ?? 0) -
              (before?['cpu_ms'] as num? ?? 0),
          'warning': 'Ambient microphone; two short PTT sessions per window; Safety cancellations retained. This does not measure critical warning recall.',
        };
        emit('performance', row);
        rows.add(row);
      }
      await camera.stopDetection();
      await const MethodChannel('navigation/vosk').invokeMethod('saveReport', {
        'name': 'vosk-recognition-fix-performance.json',
        'json': jsonEncode(rows),
      });
      emit('complete', {'type': 'performance', 'windows': rows.length});
      if (mounted) setState(() => status = 'Замеры завершены');
    } catch (error) {
      emit('error', error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      LiveCameraPage(key: cameraKey),
      Positioned(
        top: 80,
        left: 8,
        right: 8,
        child: Material(
          elevation: 8,
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  trial >= 80
                      ? '80 проб завершено'
                      : 'Проба ${trial + 1}/80: $expected',
                  style: const TextStyle(fontSize: 22),
                ),
                Text(status, maxLines: 3),
                if (!const bool.fromEnvironment('VOSK_PERF_ONLY'))
                  ElevatedButton(
                    onPressed: busy || !prepared || trial >= 80
                        ? null
                        : attempt,
                    child: Text(busy ? 'Слушаю / обрабатываю…' : 'Проба'),
                  ),
                if (trial == 60 && !busy && !silenceBatch)
                  ElevatedButton(
                    onPressed: () async {
                      silenceBatch = true;
                      while (mounted && trial < 80) {
                        final previous = trial;
                        await attempt();
                        if (previous == trial) break;
                        await Future<void>.delayed(
                          const Duration(milliseconds: 500),
                        );
                      }
                    },
                    child: const Text('Начать 20 проб тишины'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
