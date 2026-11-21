// Controlled release validation of the real page, real camera, LAN and shared TTS.
// Saves only text and timings; never saves or logs JPEGs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yolo_live_detection/app_config.dart';
import 'package:yolo_live_detection/live_camera_page.dart';
import 'package:yolo_live_detection/services/vlm_service.dart';
import 'package:yolo_live_detection/safety_tts_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('OFFLINE_ONLY') ||
      !const bool.fromEnvironment('VLM_DIAGNOSTICS_ENABLED')) {
    throw StateError('Explicit offline VLM validation build required');
  }
  await AppConfig.load();
  runApp(const MaterialApp(home: VlmValidation()));
}

class VlmValidation extends StatefulWidget {
  const VlmValidation({super.key});
  @override
  State<VlmValidation> createState() => _VlmValidationState();
}

class _VlmValidationState extends State<VlmValidation> {
  final cameraKey = GlobalKey();
  final rows = <Map<String, dynamic>>[];
  dynamic get camera => cameraKey.currentState;
  VlmService get vlm => camera.diagnosticVlm as VlmService;
  SafetyTtsService get speech => camera.diagnosticSpeech as SafetyTtsService;
  String scene = 'Комната / мебель', phase = 'manual', status = 'Подготовка';
  String? lastRequest;
  bool prepared = false, automatic = false;
  Map<String, dynamic>? lastManual;
  Future<void> saving = Future.value();
  Timer? remoteTimer;
  bool readingCommand = false;
  String? lastCommand, lastState;
  final file = File(
    '/storage/emulated/0/Android/data/com.example.camera/files/qwen8/android-validation.json',
  );
  Future<void> until(bool Function() condition, {int seconds = 60}) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (!mounted || watch.elapsed > Duration(seconds: seconds)) {
        throw TimeoutException('Validation timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void save(Map<String, dynamic> row) {
    rows.add({
      'time': DateTime.now().toUtc().toIso8601String(),
      'phase': phase,
      'scene': scene,
      ...row,
    });
    final json = const JsonEncoder.withIndent('  ').convert(rows);
    saving = saving.then((_) async {
      await file.parent.create(recursive: true);
      await file.writeAsString(json);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await file.exists()) {
        rows.addAll(
          (jsonDecode(await file.readAsString()) as List).map(
            (row) => Map<String, dynamic>.from(row as Map),
          ),
        );
      }
      final commands = rows.where((row) => row['type'] == 'command');
      if (commands.isNotEmpty) lastCommand = commands.last['id'] as String?;
      await until(
        () => camera != null && camera.controller?.value.isInitialized == true,
      );
      final previous = vlm.onChanged;
      vlm.onChanged = () {
        previous?.call();
        if (lastState != vlm.state.name) {
          lastState = vlm.state.name;
          save({
            'type': 'state',
            'state': vlm.state.name,
            'detector_running': camera.running,
          });
        }
        final metrics = vlm.lastMeasurement;
        if (metrics != null && metrics['request_id'] != lastRequest) {
          lastRequest = metrics['request_id'] as String;
          final row = <String, dynamic>{
            'type': 'response',
            'measurement': metrics,
            'detector_running': camera.running,
            'yolo_fps': camera.fps,
            'camera_to_result_ms': camera.cameraToResultMs,
            'rss_bytes': ProcessInfo.currentRss,
          };
          if (phase == 'manual') lastManual = row;
          save(row);
        } else if (vlm.state == VlmState.error ||
            vlm.state == VlmState.cancelled) {
          save({
            'type': vlm.state.name,
            'status': vlm.statusText,
            'detector_running': camera.running,
          });
        }
        if (mounted) setState(() {});
      };
      if (mounted) {
        setState(() {
          prepared = true;
          status = 'Нажмите «Автотест», затем проверьте знакомые сцены';
        });
      }
      if (const bool.fromEnvironment('VLM_PERF_ONLY')) {
        unawaited(runPerformance());
      } else if (const bool.fromEnvironment('VLM_AUTO_TEST')) {
        unawaited(runAutomatic());
      }
      if (const bool.fromEnvironment('VLM_REMOTE_TEST')) {
        remoteTimer = Timer.periodic(
          const Duration(milliseconds: 200),
          (_) => readRemoteCommand(),
        );
      }
    });
  }

  Future<void> readRemoteCommand() async {
    if (readingCommand || !mounted) return;
    readingCommand = true;
    try {
      final commandFile = File('${file.parent.path}/command.json');
      if (!await commandFile.exists()) return;
      final command = jsonDecode(await commandFile.readAsString()) as Map;
      final id = command['id'] as String;
      if (id == lastCommand || !mounted) return;
      lastCommand = id;
      phase = command['phase'] as String? ?? 'remote';
      save({'type': 'command', 'id': id, 'action': command['action']});
      switch (command['action']) {
        case 'start':
          await camera.startDetection();
          save({'type': 'command_done', 'id': id, 'running': camera.running});
        case 'stop':
          await camera.stopDetection();
          save({'type': 'command_done', 'id': id, 'running': camera.running});
        case 'cancel':
          camera.cancelEnvironmentDescription();
          save({'type': 'command_done', 'id': id, 'state': vlm.state.name});
        case 'describe':
          unawaited(
            (camera.describeEnvironment() as Future<String?>).then((text) {
              save({
                'type': 'command_done',
                'id': id,
                'result_present': text != null,
                'state': vlm.state.name,
              });
            }),
          );
      }
    } catch (_) {
      // adb push can be observed before the tiny JSON file is fully replaced.
    } finally {
      readingCommand = false;
    }
  }

  @override
  void dispose() {
    remoteTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> sampleDetector(
    int seconds,
    Future<void>? job,
  ) async {
    var count = 0;
    dynamic previous = camera.lastResult;
    final watch = Stopwatch()..start();
    final latencies = <double>[];
    while (watch.elapsed < Duration(seconds: seconds)) {
      final current = camera.lastResult;
      if (current != null && current != previous) {
        previous = current;
        count++;
        latencies.add((camera.cameraToResultMs as num).toDouble());
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final sampledMs = watch.elapsedMilliseconds;
    await job;
    latencies.sort();
    return {
      'type': 'throughput',
      'window_ms': sampledMs,
      'results': count,
      'results_per_second': count / seconds,
      'camera_p50_ms': latencies.isEmpty
          ? null
          : latencies[latencies.length ~/ 2],
      'camera_p95_ms': latencies.isEmpty
          ? null
          : latencies[((latencies.length - 1) * .95).ceil()],
    };
  }

  Future<void> runAutomatic() async {
    if (!prepared || automatic) return;
    setState(() {
      automatic = true;
      status = 'Автотест: камера, LAN, YOLO и TTS';
    });
    try {
      phase = 'camera_off';
      await camera.stopDetection();
      final off = await camera.describeEnvironment();
      save({
        'type': 'assertion',
        'check': 'camera_off_no_upload',
        'passed': off == null && !vlm.isBusy,
      });
      await camera.startDetection();
      await until(() => camera.lastResult != null);
      phase = 'baseline';
      save(await sampleDetector(10, null));
      phase = 'vlm_and_critical_tts';
      final pending = camera.describeEnvironment() as Future<String?>;
      await until(
        () => vlm.state == VlmState.processing || vlm.state == VlmState.error,
      );
      final duplicate = await camera.describeEnvironment();
      save({
        'type': 'assertion',
        'check': 'duplicate_tap_ignored',
        'passed': duplicate == null,
      });
      await until(
        () => vlm.state == VlmState.speaking || vlm.state == VlmState.error,
      );
      if (vlm.state == VlmState.speaking) {
        await until(() => speech.currentText.startsWith('На '));
        final now = DateTime.now();
        speech.onFrame([
          SafetyAlert(
            key: 'qwen-priority-test',
            text: 'Тест: приоритет три',
            priority: 3,
            observedAt: now,
          ),
        ]);
        await until(
          () => speech.currentText == 'Тест: приоритет три',
          seconds: 3,
        );
        save({
          'type': 'assertion',
          'check': 'critical_preempts_vlm',
          'passed': true,
          'note': 'Injected confirmed priority-3 TEST alert; not a real obstacle detection.',
        });
        camera.cancelEnvironmentDescription();
        save({
          'type': 'assertion',
          'check': 'cancel_vlm_preserves_critical',
          'passed': speech.currentText == 'Тест: приоритет три',
        });
      }
      await pending;
      await until(() => !speech.isSpeaking);
      phase = 'cancel_http';
      final cancelled = camera.describeEnvironment() as Future<String?>;
      await until(
        () => vlm.state == VlmState.processing || vlm.state == VlmState.error,
      );
      camera.cancelEnvironmentDescription();
      save({
        'type': 'assertion',
        'check': 'cancelled_result_not_spoken',
        'passed': await cancelled == null,
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      phase = 'close_camera';
      final closed = camera.describeEnvironment() as Future<String?>;
      await until(
        () => vlm.state == VlmState.processing || vlm.state == VlmState.error,
      );
      await camera.stopDetection();
      save({
        'type': 'assertion',
        'check': 'close_camera_invalidates_request',
        'passed': await closed == null && camera.running == false,
      });
      await camera.startDetection();
      await until(() => camera.lastResult != null);
      await until(() => !speech.isSpeaking);
      phase = 'throughput_with_vlm';
      final description = camera.describeEnvironment() as Future<String?>;
      // Measure detector while inference and description run; do not wait from the camera callback.
      save(await sampleDetector(10, description.then((_) {})));
      phase = 'manual';
      if (mounted) {
        setState(
          () => status = 'Автотест завершён. Выберите сцену и нажмите «Описать окружение» внизу.',
        );
      }
    } catch (error) {
      save({'type': 'validation_error', 'error': error.toString()});
      phase = 'manual';
      if (mounted) setState(() => status = error.toString());
    } finally {
      if (mounted) setState(() => automatic = false);
    }
  }

  Future<void> runPerformance() async {
    if (!prepared || automatic) return;
    setState(() {
      automatic = true;
      status = 'Замеры YOLO: 4 окна по 20 секунд';
    });
    try {
      await camera.startDetection();
      await until(() => camera.lastResult != null);
      await Future<void>.delayed(const Duration(seconds: 5));
      var index = 0;
      for (final active in [false, true, true, false]) {
        phase = 'performance-${++index}-${active ? 'vlm' : 'baseline'}';
        var finished = false, attempts = 0;
        Future<void> requestLoad() async {
          for (var i = 0; i < 2 && !finished; i++) {
            attempts++;
            await camera.describeEnvironment();
            if (!finished) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
          }
        }

        final before = await const MethodChannel('navigation/performance')
            .invokeMapMethod<String, dynamic>('snapshot');
        final job = active ? requestLoad() : Future<void>.value();
        final measured = await sampleDetector(20, null);
        final after = await const MethodChannel('navigation/performance')
            .invokeMapMethod<String, dynamic>('snapshot');
        finished = true;
        camera.cancelEnvironmentDescription();
        await job;
        save({
          ...measured,
          'vlm_active': active,
          'requests_attempted': attempts,
          'cpu_ms':
              (after?['cpu_ms'] as num? ?? 0) -
              (before?['cpu_ms'] as num? ?? 0),
          'rss_bytes': ProcessInfo.currentRss,
          'note': 'Two bounded on-demand requests planned; shared TTS and real Safety remain active.',
        });
      }
      phase = 'manual';
      if (mounted) setState(() => status = 'Замеры YOLO завершены');
    } catch (error) {
      save({'type': 'validation_error', 'error': error.toString()});
      phase = 'manual';
    } finally {
      if (mounted) setState(() => automatic = false);
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      LiveCameraPage(key: cameraKey),
      Positioned(
        top: 68,
        left: 6,
        right: 6,
        child: Material(
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(status, maxLines: 3),
                if (!automatic)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: prepared ? runAutomatic : null,
                        child: const Text('Автотест'),
                      ),
                      DropdownButton<String>(
                        value: scene,
                        items:
                            [
                                  'Комната / мебель',
                                  'Дверь',
                                  'Коридор',
                                  'Лестница',
                                  'Отказы сети',
                                ]
                                .map(
                                  (v) => DropdownMenuItem(
                                    value: v,
                                    child: Text(v),
                                  ),
                                )
                                .toList(),
                        onChanged: (v) => setState(() {
                          scene = v!;
                          lastManual = null;
                        }),
                      ),
                    ],
                  ),
                if (lastManual != null && !automatic)
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: () {
                          save({
                            'type': 'human_review',
                            'request_id':
                                (lastManual!['measurement']
                                    as Map)['request_id'],
                            'objects_and_directions_correct': true,
                          });
                          setState(() => lastManual = null);
                        },
                        child: const Text('Объекты и стороны верны'),
                      ),
                      TextButton(
                        onPressed: () {
                          save({
                            'type': 'human_review',
                            'request_id':
                                (lastManual!['measurement']
                                    as Map)['request_id'],
                            'objects_and_directions_correct': false,
                          });
                          setState(() => lastManual = null);
                        },
                        child: const Text('Есть ошибка'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
