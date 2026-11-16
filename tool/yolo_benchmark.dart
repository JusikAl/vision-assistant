// Run on an Android device: flutter run --profile -t tool/yolo_benchmark.dart
// Synthetic NV21 only: no camera, microphone, network or extra dependencies.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:yolo_live_detection/services/local_yolo_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Offline YOLO benchmark. Results in Logcat.')),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_benchmark()));
}

Future<void> _benchmark() async {
  final bytes = Uint8List(640 * 480 * 3 ~/ 2)..fillRange(0, 640 * 480, 114);
  bytes.fillRange(640 * 480, bytes.length, 128);
  // A synthetic legacy camera message avoids adding a platform-interface
  // dependency solely for this standalone benchmark.
  // ignore: deprecated_member_use
  final frame = CameraImage.fromPlatformData({
    'format': 17,
    'width': 640,
    'height': 480,
    'planes': [
      {'bytes': bytes, 'bytesPerRow': 640},
    ],
  });
  for (final config in [
    (false, 1),
    (false, 2),
    (false, 4),
    (true, 1),
    (true, 2),
    (true, 4),
  ]) {
    final service = LocalYoloService(useXnnpack: config.$1, threads: config.$2);
    try {
      await service.initialize();
      service.beginSession();
      final inference = <double>[];
      final totals = <double>[];
      for (var i = 0; i < 8; i++) {
        final result = await service.detectNv21(frame, 90);
        inference.add(result.yoloMs);
        totals.add(result.processingMs);
      }
      inference.sort();
      totals.sort();
      debugPrint(
        'BENCH xnnpack=${config.$1} threads=${config.$2} '
        'frames=${inference.length} median_inference_ms=${inference[4]} '
        'p95_inference_ms=${inference.last} median_frame_total_ms=${totals[4]} '
        'warmup_ms=${service.warmupInferenceMs}',
      );
      // Verify Stop/Start drains a native frame without unloading the worker.
      final cancelled = service.detectNv21(frame, 90);
      final checked = cancelled.then<void>(
        (_) => throw StateError('Expected cancel'),
        onError: (Object e) {
          if (e is! YoloRequestCancelled) throw e;
        },
      );
      service.cancelPending();
      await checked;
      if (!service.isBusy) {
        throw StateError('Cancelled native slot freed early');
      }
      while (service.isBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final restart = Stopwatch()..start();
      await service.initialize();
      service.beginSession();
      await service.detectNv21(frame, 90);
      debugPrint(
        'BENCH restart_ok=true xnnpack=${config.$1} '
        'threads=${config.$2} restart_to_result_ms='
        '${restart.elapsedMicroseconds / 1000}',
      );
    } catch (error, stack) {
      debugPrint('BENCH ERROR $config $error\n$stack');
    } finally {
      await service.dispose();
    }
  }
  final model = await rootBundle.load(LocalYoloService.modelAssetPath);
  final modelBytes = model.buffer.asUint8List(
    model.offsetInBytes,
    model.lengthInBytes,
  );
  await Isolate.run(() => _validateXnnpack(modelBytes));
  debugPrint('BENCH COMPLETE');
}

// Compare FP32 raw outputs, including scores, on reproducible non-uniform input.
// This checks numerical parity, not dataset accuracy or navigation safety.
void _validateXnnpack(Uint8List bytes) {
  final delegateOptions = XNNPackDelegateOptions(numThreads: 4);
  final delegate = XNNPackDelegate(options: delegateOptions);
  delegateOptions.delete();
  final cpuOptions = InterpreterOptions()..threads = 4;
  final fastOptions = InterpreterOptions()
    ..threads = 4
    ..addDelegate(delegate);
  final cpu = Interpreter.fromBuffer(bytes, options: cpuOptions);
  final fast = Interpreter.fromBuffer(bytes, options: fastOptions);
  cpuOptions.delete();
  fastOptions.delete();
  try {
    final random = math.Random(42);
    for (var sample = 0; sample < 3; sample++) {
      final input = Float32List(3 * 320 * 320);
      for (var i = 0; i < input.length; i++) {
        input[i] = random.nextDouble();
      }
      cpu.getInputTensor(0).data = input.buffer.asUint8List();
      fast.getInputTensor(0).data = input.buffer.asUint8List();
      cpu.invoke();
      fast.invoke();
      final referenceBytes = cpu.getOutputTensor(0).data;
      final actualBytes = fast.getOutputTensor(0).data;
      final reference = referenceBytes.buffer.asFloat32List(
        referenceBytes.offsetInBytes,
        referenceBytes.lengthInBytes ~/ 4,
      );
      final actual = actualBytes.buffer.asFloat32List(
        actualBytes.offsetInBytes,
        actualBytes.lengthInBytes ~/ 4,
      );
      var maxError = 0.0;
      var maxScoreError = 0.0;
      var outsideTolerance = 0;
      for (var i = 0; i < reference.length; i++) {
        final error = (reference[i] - actual[i]).abs();
        if (!error.isFinite || error > 0.0001 + reference[i].abs() * 0.001) {
          outsideTolerance++;
        }
        maxError = math.max(maxError, error);
        if (i >= 4 * 2100) maxScoreError = math.max(maxScoreError, error);
      }
      debugPrint(
        'BENCH PARITY sample=$sample max_abs_error=$maxError '
        'max_score_error=$maxScoreError outside_tolerance=$outsideTolerance',
      );
      if (outsideTolerance > 0) {
        throw StateError('XNNPACK output parity failed');
      }
    }
  } finally {
    cpu.close();
    fast.close();
    delegate.delete();
  }
}
