// flutter run --profile -t tool/yolo_camera_smoke.dart
//   --dart-define=OFFLINE_ONLY=true -d <device>
// Runs the real page/camera lifecycle. Never use this without OFFLINE_ONLY.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yolo_live_detection/app_config.dart';
import 'package:yolo_live_detection/live_camera_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('OFFLINE_ONLY')) {
    throw StateError('Camera smoke test requires OFFLINE_ONLY=true');
  }
  await AppConfig.load();
  final key = GlobalKey();
  runApp(MaterialApp(home: LiveCameraPage(key: key)));
  unawaited(_exerciseCamera(key));
}

Future<void> _waitUntil(bool Function() condition, String stage) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 40)) {
      throw TimeoutException('CAMERA SMOKE timeout: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> _exerciseCamera(GlobalKey key) async {
  try {
    await _waitUntil(() => key.currentState != null, 'page mounted');
    final dynamic state = key.currentState;
    await _waitUntil(
      () => state.controller?.value.isInitialized == true,
      'camera initialized',
    );
    // Allow preload to finish; cold-start time remains in OFFLINE INIT logs.
    await Future<void>.delayed(const Duration(seconds: 3));
    const sessions = int.fromEnvironment(
      'CAMERA_SMOKE_SESSIONS',
      defaultValue: 3,
    );
    for (var session = 1; session <= sessions; session++) {
      await state.startDetection();
      await _waitUntil(() => state.lastResult != null, 'first camera result');
      const diagnostics = MethodChannel('navigation/performance');
      final before =
          await diagnostics.invokeMapMethod<String, dynamic>('snapshot') ?? {};
      final samples = <Map<String, double>>[];
      DateTime? previous;
      final measurement = Stopwatch()..start();
      while (measurement.elapsed < const Duration(seconds: 8)) {
        final DateTime? resultAt = state.lastResult;
        if (resultAt != null && resultAt != previous) {
          previous = resultAt;
          samples.add({
            'inference_ms': state.yoloMs as double,
            'frame_ms': state.processingMs as double,
            'preprocess_ms': state.offlinePreprocessMs as double,
            'postprocess_ms': state.offlinePostprocessMs as double,
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final after =
          await diagnostics.invokeMapMethod<String, dynamic>('snapshot') ?? {};
      final stats = <String, Object>{
        'session': session,
        'n': samples.length,
        'rss_bytes': ProcessInfo.currentRss,
      };
      stats['measurement_ms'] = measurement.elapsedMilliseconds;
      stats['native_snapshot'] = after;
      for (final key in [
        'cpu_ms',
        'java_allocated_bytes',
        'java_gc_count',
        'java_gc_ms',
      ]) {
        stats['${key}_delta'] =
            ((after[key] as num?) ?? 0) - ((before[key] as num?) ?? 0);
      }
      final packingBefore = before['camera_packing'] as Map?;
      final packingAfter = after['camera_packing'] as Map?;
      if (packingBefore != null && packingAfter != null) {
        final calls =
            (packingAfter['calls'] as num) - (packingBefore['calls'] as num);
        final nanos =
            (packingAfter['nanos'] as num) - (packingBefore['nanos'] as num);
        stats['native_packing_calls'] = calls;
        if (calls > 0) stats['native_packing_ms_avg'] = nanos / calls / 1000000;
      }
      for (final metric in [
        'inference_ms',
        'frame_ms',
        'preprocess_ms',
        'postprocess_ms',
      ]) {
        final values = samples.map((s) => s[metric]!).toList()..sort();
        if (values.isNotEmpty) {
          stats['${metric}_p50'] = values[values.length ~/ 2];
          stats['${metric}_p95'] = values[((values.length - 1) * .95).ceil()];
        }
      }
      for (final metric in [
        'inference_ms',
        'frame_ms',
        'preprocess_ms',
        'postprocess_ms',
      ]) {
        debugPrint(
          'CAMERA SAMPLES session=$session metric=$metric values=${jsonEncode(samples.map((s) => s[metric]).toList())}',
        );
      }
      debugPrint('CAMERA STATS ${jsonEncode(stats)}');
      debugPrint(
        'CAMERA SMOKE session=$session status=${state.status} '
        'inference_ms=${state.yoloMs} frame_total_ms=${state.processingMs} '
        'fps=${state.fps} objects=${state.detections.length}',
      );
      await state.stopDetection();
      if (state.running == true) throw StateError('Stop did not stop');
      // Short pause exercises a quick restart while old frames may be draining.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    debugPrint('CAMERA SMOKE COMPLETE');
  } catch (error, stack) {
    debugPrint('CAMERA SMOKE ERROR $error\n$stack');
    final dynamic state = key.currentState;
    if (state != null) await state.stopDetection();
  }
}
