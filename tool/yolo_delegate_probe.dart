// Standalone opt-in probe. Never changes the production delegate selection.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:yolo_live_detection/services/local_yolo_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Delegate probe'))),
    ),
  );
  final data = await rootBundle.load(LocalYoloService.modelAssetPath);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  await Isolate.run(() => probe(bytes));
}

void probe(Uint8List model) {
  const mode = String.fromEnvironment('PROBE_DELEGATE', defaultValue: 'nnapi');
  final input = Float32List(3 * 320 * 320);
  final random = Random(42);
  for (var i = 0; i < input.length; i++) {
    input[i] = random.nextDouble();
  }
  final cpuOptions = InterpreterOptions()..threads = 4;
  final cpu = Interpreter.fromBuffer(model, options: cpuOptions);
  cpuOptions.delete();
  late final Float32List reference;
  try {
    cpu.getInputTensor(0).data = input.buffer.asUint8List();
    cpu.invoke();
    final output = cpu.getOutputTensor(0).data;
    reference = Float32List.fromList(
      output.buffer.asFloat32List(
        output.offsetInBytes,
        output.lengthInBytes ~/ 4,
      ),
    );
  } finally {
    cpu.close();
  }
  GpuDelegateV2? gpu;
  XNNPackDelegate? xnn;
  Interpreter? engine;
  final options = InterpreterOptions()..threads = 4;
  try {
    if (mode == 'xnnpack') {
      final delegateOptions = XNNPackDelegateOptions(numThreads: 4);
      try {
        xnn = XNNPackDelegate(options: delegateOptions);
      } finally {
        delegateOptions.delete();
      }
      options.addDelegate(xnn);
    } else if (mode == 'nnapi') {
      options.useNnApiForAndroid = true;
    } else if (mode == 'gpu') {
      gpu = GpuDelegateV2();
      if (gpu.base.address == 0) throw StateError('GPU returned null');
      options.addDelegate(gpu);
    } else {
      throw ArgumentError(mode);
    }
    // Creation, invoke and destruction are synchronous in one callback. The
    // event-driven production worker does not enable this GPU experiment.
    engine = Interpreter.fromBuffer(model, options: options);
    final tensor = engine.getInputTensor(0);
    tensor.data = input.buffer.asUint8List();
    engine.invoke(); // warm-up excluded
    final timings = <double>[];
    for (var i = 0; i < 8; i++) {
      tensor.data = input.buffer.asUint8List();
      final watch = Stopwatch()..start();
      engine.invoke();
      timings.add(watch.elapsedMicroseconds / 1000);
    }
    final output = engine.getOutputTensor(0).data;
    final actual = output.buffer.asFloat32List(
      output.offsetInBytes,
      output.lengthInBytes ~/ 4,
    );
    var bad = 0;
    var maxError = 0.0;
    for (var i = 0; i < reference.length; i++) {
      final error = (actual[i] - reference[i]).abs();
      if (!error.isFinite || error > .0001 + reference[i].abs() * .001) bad++;
      maxError = max(maxError, error);
    }
    timings.sort();
    debugPrint(
      'DELEGATE PROBE mode=$mode p50_ms=${timings[4]} p95_ms=${timings.last} '
      'outside_tolerance=$bad max_abs_error=$maxError rss_bytes=${ProcessInfo.currentRss}',
    );
  } catch (error, stack) {
    debugPrint(
      'DELEGATE PROBE unavailable mode=$mode error=$error stack=$stack',
    );
  } finally {
    engine?.close();
    gpu?.delete();
    xnn?.delete();
    options.delete();
  }
  debugPrint(
    'DELEGATE PROBE COMPLETE mode=$mode production_default_unchanged=true',
  );
}
