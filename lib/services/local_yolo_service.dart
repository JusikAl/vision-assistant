import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'yolo_postprocessor.dart';
import 'yolo_preprocessor.dart';

// CPU only. Android XNNPACK is enabled after device validation; NNAPI/GPU
// require separate accuracy, driver and native-thread affinity validation.
const int _kThreads = int.fromEnvironment('YOLO_THREADS', defaultValue: 4);
const bool _kXnnpack = bool.fromEnvironment('YOLO_XNNPACK', defaultValue: true);
const int _kInputSize = 320;

class LocalYoloResult {
  const LocalYoloResult({
    required this.detections,
    required this.imageWidth,
    required this.imageHeight,
    required this.processingMs,
    required this.yoloMs,
    required this.preprocessMs,
    required this.postprocessMs,
    required this.workerMs,
    required this.inputCopyMs,
    required this.isFirstFrame,
    required this.fps,
    this.transferMs = 0,
    this.materializeMs = 0,
    this.outputReadMs = 0,
  });

  final List<Map<String, dynamic>> detections;
  final int imageWidth;
  final int imageHeight;
  final double processingMs;
  final double yoloMs;
  final double preprocessMs;
  final double postprocessMs;
  final double workerMs;
  final double inputCopyMs;
  final bool isFirstFrame;
  final double fps;
  final double transferMs, materializeMs, outputReadMs;
}

class _WorkerInit {
  const _WorkerInit(this.replyPort, this.model, this.threads, this.useXnnpack);
  final SendPort replyPort;
  final TransferableTypedData model;
  final int threads;
  final bool useXnnpack;
}

class _WorkerFrame {
  const _WorkerFrame({
    required this.id,
    required this.nv21,
    required this.width,
    required this.height,
    required this.rowStride,
    required this.rotation,
  });

  final int id;
  final TransferableTypedData nv21;
  final int width;
  final int height;
  final int rowStride;
  final int rotation;
}

class _PendingFrame {
  _PendingFrame(this.id);
  final int id;
  final Stopwatch elapsed = Stopwatch()..start();
  Timer? slowTimer;
  double transferMs = 0;
  final Completer<LocalYoloResult> completer = Completer<LocalYoloResult>();
}

class YoloRequestCancelled implements Exception {
  const YoloRequestCancelled();
  @override
  String toString() => 'YOLO request cancelled';
}

// The interpreter is created, used and destroyed in the SAME isolate.
void _localYoloWorker(dynamic configuration) {
  final init = configuration as _WorkerInit;
  final replyPort = init.replyPort;
  final commands = ReceivePort();

  Interpreter? interpreter;
  XNNPackDelegate? delegate;
  final initWatch = Stopwatch()..start();
  double warmupMs = 0;
  var frameNumber = 0;
  late final Tensor inputTensor;
  late final Tensor outputTensor;
  late final List<int> outputShape;
  late final bool nhwc;
  final inputBuffer = Float32List(3 * _kInputSize * _kInputSize);

  try {
    final bytes = init.model.materialize().asUint8List();
    late final Interpreter engine;
    // Explicit XNNPACK is validated with the pinned Android runtime. Missing
    // symbols or delegate setup errors fall back to the original CPU path.
    Interpreter createEngine(bool accelerated) {
      final options = InterpreterOptions()..threads = init.threads;
      try {
        if (accelerated) {
          final delegateOptions = XNNPackDelegateOptions(
            numThreads: init.threads,
          );
          try {
            delegate = XNNPackDelegate(options: delegateOptions);
            if (delegate!.base.address == 0) {
              throw StateError('XNNPACK delegate creation returned null');
            }
            options.addDelegate(delegate!);
          } finally {
            delegateOptions.delete();
          }
        }
        return Interpreter.fromBuffer(bytes, options: options);
      } finally {
        options.delete();
      }
    }

    try {
      engine = createEngine(init.useXnnpack && Platform.isAndroid);
    } catch (error) {
      if (delegate == null && !(init.useXnnpack && Platform.isAndroid)) rethrow;
      delegate?.delete();
      delegate = null;
      debugPrint('OFFLINE XNNPACK fallback to CPU: $error');
      engine = createEngine(false);
    }
    interpreter = engine;

    inputTensor = engine.getInputTensor(0);
    outputTensor = engine.getOutputTensor(0);
    final inputShape = List<int>.from(inputTensor.shape);
    outputShape = List<int>.from(outputTensor.shape);

    if (inputTensor.type != TensorType.float32 ||
        outputTensor.type != TensorType.float32) {
      throw StateError(
        'Only float32 YOLO model is supported. '
        'Input=${inputTensor.type}, output=${outputTensor.type}',
      );
    }

    if (inputShape.length == 4 &&
        inputShape[0] == 1 &&
        inputShape[1] == _kInputSize &&
        inputShape[2] == _kInputSize &&
        inputShape[3] == 3) {
      nhwc = true;
    } else if (inputShape.length == 4 &&
        inputShape[0] == 1 &&
        inputShape[1] == 3 &&
        inputShape[2] == _kInputSize &&
        inputShape[3] == _kInputSize) {
      nhwc = false;
    } else {
      throw StateError('Unsupported YOLO input shape: $inputShape');
    }

    const channels = YoloPostprocessor.channels;
    const candidates = YoloPostprocessor.candidatesCount;
    final validOutput =
        outputShape.length == 3 &&
        outputShape[0] == 1 &&
        ((outputShape[1] == channels && outputShape[2] == candidates) ||
            (outputShape[1] == candidates && outputShape[2] == channels));
    if (!validOutput) {
      throw StateError('Unsupported YOLO output shape: $outputShape');
    }

    if (inputTensor.numBytes() != 3 * _kInputSize * _kInputSize * 4 ||
        outputTensor.numBytes() != channels * candidates * 4) {
      throw StateError('Unexpected float32 YOLO tensor byte length');
    }

    initWatch.stop();
    final warmup = Float32List(3 * _kInputSize * _kInputSize);
    warmup.fillRange(0, warmup.length, 114 / 255);
    inputTensor.data = warmup.buffer.asUint8List();
    final warmupWatch = Stopwatch()..start();
    engine.invoke();
    warmupMs = warmupWatch.elapsedMicroseconds / 1000;
    debugPrint(
      'OFFLINE YOLO ready: CPU threads=${init.threads}, '
      'explicit_xnnpack=${delegate != null}',
    );
    debugPrint('OFFLINE YOLO shapes: $inputShape -> $outputShape');
  } catch (e, st) {
    try {
      interpreter?.close();
      delegate?.delete();
    } catch (_) {}
    replyPort.send({
      'type': 'init_error',
      'error': e.toString(),
      'stack': st.toString(),
    });
    commands.close();
    return;
  }

  final activeInterpreter = interpreter;
  replyPort.send({
    'type': 'ready',
    'port': commands.sendPort,
    'interpreterInitMs': initWatch.elapsedMicroseconds / 1000,
    'warmupMs': warmupMs,
    'xnnpackActive': delegate != null,
  });

  commands.listen((dynamic message) {
    if (message == 'dispose') {
      try {
        activeInterpreter.close();
        delegate?.delete();
      } catch (_) {}
      commands.close();
      replyPort.send({'type': 'disposed'});
      return;
    }
    if (message is! _WorkerFrame) return;

    final total = Stopwatch()..start();
    try {
      final materializeWatch = Stopwatch()..start();
      final nv21 = message.nv21.materialize().asUint8List();
      materializeWatch.stop();
      final prepWatch = Stopwatch()..start();
      final prepared = prepareYoloInputFromNv21(
        nv21: nv21,
        width: message.width,
        height: message.height,
        rowStride: message.rowStride,
        rotation: message.rotation,
        nhwc: nhwc,
        outputBuffer: inputBuffer,
      );
      prepWatch.stop();

      final copyWatch = Stopwatch()..start();
      inputTensor.data = prepared.bytes;
      copyWatch.stop();
      final inferenceWatch = Stopwatch()..start();
      activeInterpreter.invoke();
      inferenceWatch.stop();
      final outputWatch = Stopwatch()..start();
      final outputBytes = outputTensor.data;
      final outputFloat32 = Float32List.view(
        outputBytes.buffer,
        outputBytes.offsetInBytes,
        outputBytes.lengthInBytes ~/ Float32List.bytesPerElement,
      );
      outputWatch.stop();
      final postWatch = Stopwatch()..start();
      final detections = YoloPostprocessor.decodeFromFloat32(
        outputFloat32,
        outputShape,
        prepared,
      );
      postWatch.stop();
      total.stop();

      replyPort.send({
        'type': 'result',
        'id': message.id,
        'ok': true,
        'firstFrame': ++frameNumber == 1,
        'inputCopyMs': copyWatch.elapsedMicroseconds / 1000,
        'materializeMs': materializeWatch.elapsedMicroseconds / 1000,
        'outputReadMs': outputWatch.elapsedMicroseconds / 1000,
        'detections': detections,
        'imageWidth': prepared.sourceWidth,
        'imageHeight': prepared.sourceHeight,
        'processingMs': total.elapsedMicroseconds / 1000.0,
        'yoloMs': inferenceWatch.elapsedMicroseconds / 1000.0,
        'preprocessMs': prepWatch.elapsedMicroseconds / 1000.0,
        'postprocessMs': postWatch.elapsedMicroseconds / 1000.0,
      });
    } catch (e, st) {
      replyPort.send({
        'type': 'result',
        'id': message.id,
        'ok': false,
        'error': e.toString(),
        'stack': st.toString(),
      });
    }
  });
}

class LocalYoloService {
  static const modelAssetPath = 'assets/models/yolo11n_rod.tflite';

  LocalYoloService({
    this.threads = _kThreads,
    this.useXnnpack = _kXnnpack,
    this.slowFrameThreshold = const Duration(seconds: 20),
    @visibleForTesting this.modelLoader,
    @visibleForTesting this.workerEntryPoint,
  }) {
    if (threads < 1 || threads > 8) {
      throw ArgumentError.value(threads, 'threads', 'Expected 1..8');
    }
  }

  final int threads;
  final bool useXnnpack;
  final Duration slowFrameThreshold;
  final Future<ByteData> Function()? modelLoader;
  final void Function(dynamic)? workerEntryPoint;
  static const Duration _initTimeout = Duration(seconds: 90);

  bool get isReady => _workerSend != null && !_disposed;
  bool get isBusy => _pending != null;
  double modelLoadMs = 0;
  double interpreterInitMs = 0;
  double warmupInferenceMs = 0;
  bool xnnpackActive = false;
  final Stopwatch _cadence = Stopwatch();

  Isolate? _isolate;
  SendPort? _workerSend;
  ReceivePort? _receivePort;
  ReceivePort? _errorPort;
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<dynamic>? _errorSubscription;

  Completer<void>? _ready;
  Completer<void>? _disposeAck;
  _PendingFrame? _pending;
  Future<void>? _starting;

  bool _disposed = false;
  int _nextFrameId = 0;
  int _completedFrames = 0;

  Future<void> initialize() {
    if (_disposed) {
      return Future.error(StateError('Local YOLO was disposed'));
    }
    if (_workerSend != null) return Future.value();
    return _starting ??= _start().whenComplete(() {
      _starting = null;
    });
  }

  Future<void> _start() async {
    final startupWatch = Stopwatch()..start();
    final loadWatch = Stopwatch()..start();
    final modelData =
        await (modelLoader?.call() ?? rootBundle.load(modelAssetPath));
    modelLoadMs = loadWatch.elapsedMicroseconds / 1000;
    debugPrint('OFFLINE INIT model_load_ms=${modelLoadMs.toStringAsFixed(2)}');
    final modelBytes = modelData.buffer.asUint8List(
      modelData.offsetInBytes,
      modelData.lengthInBytes,
    );
    if (_disposed) throw StateError('Local YOLO was disposed');

    final ready = Completer<void>();
    _ready = ready;
    final receive = ReceivePort();
    final errors = ReceivePort();
    _receivePort = receive;
    _errorPort = errors;
    _subscription = receive.listen(_onWorkerMessage);
    _errorSubscription = errors.listen((dynamic event) {
      final reason = event == null
          ? 'YOLO isolate exited unexpectedly'
          : 'YOLO isolate crashed: $event';
      final ack = _disposeAck;
      if (_disposed && ack != null && event == null) {
        if (!ack.isCompleted) ack.complete();
      } else {
        unawaited(_teardown(StateError(reason)));
      }
    });

    try {
      _completedFrames = 0;
      _cadence.reset();
      _cadence.stop();
      _isolate = await Isolate.spawn<dynamic>(
        workerEntryPoint ?? _localYoloWorker,
        _WorkerInit(
          receive.sendPort,
          TransferableTypedData.fromList([modelBytes]),
          threads,
          useXnnpack,
        ),
        onError: errors.sendPort,
        onExit: errors.sendPort,
      );
      await ready.future.timeout(_initTimeout);
      debugPrint(
        'OFFLINE INIT preload_total_ms='
        '${(startupWatch.elapsedMicroseconds / 1000).toStringAsFixed(2)}',
      );
    } catch (e) {
      await _teardown(e);
      rethrow;
    }
  }

  void _onWorkerMessage(dynamic message) {
    if (message is! Map) return;

    switch (message['type']) {
      case 'ready':
        _workerSend = message['port'] as SendPort;
        xnnpackActive = message['xnnpackActive'] == true;
        interpreterInitMs = (message['interpreterInitMs'] as num).toDouble();
        warmupInferenceMs = (message['warmupMs'] as num).toDouble();
        debugPrint(
          'OFFLINE INIT interpreter_init_ms='
          '${interpreterInitMs.toStringAsFixed(2)} '
          'warmup_inference_ms=${warmupInferenceMs.toStringAsFixed(2)} '
          'first_inference=true threads=$threads explicit_xnnpack=$xnnpackActive',
        );
        final ready = _ready;
        if (ready != null && !ready.isCompleted) ready.complete();
        break;

      case 'init_error':
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(
            StateError('${message['error']}\n${message['stack']}'),
          );
        }
        break;

      case 'disposed':
        final ack = _disposeAck;
        if (ack != null && !ack.isCompleted) ack.complete();
        break;

      case 'result':
        final pending = _pending;
        if (pending == null || pending.id != message['id']) return;
        _pending = null;
        pending.slowTimer?.cancel();
        if (pending.completer.isCompleted) return;

        if (message['ok'] == true) {
          final cadenceMs = _cadence.elapsedMicroseconds / 1000;
          _cadence
            ..reset()
            ..start();
          pending.completer.complete(
            LocalYoloResult(
              detections: (message['detections'] as List)
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList(growable: false),
              imageWidth: message['imageWidth'] as int,
              imageHeight: message['imageHeight'] as int,
              processingMs: pending.elapsed.elapsedMicroseconds / 1000,
              workerMs: (message['processingMs'] as num).toDouble(),
              inputCopyMs: (message['inputCopyMs'] as num).toDouble(),
              isFirstFrame: message['firstFrame'] == true,
              fps: cadenceMs > 0 ? 1000 / cadenceMs : 0,
              transferMs: pending.transferMs,
              materializeMs:
                  (message['materializeMs'] as num?)?.toDouble() ?? 0,
              outputReadMs: (message['outputReadMs'] as num?)?.toDouble() ?? 0,
              yoloMs: (message['yoloMs'] as num).toDouble(),
              preprocessMs: (message['preprocessMs'] as num).toDouble(),
              postprocessMs: (message['postprocessMs'] as num).toDouble(),
            ),
          );
        } else {
          pending.completer.completeError(
            StateError('${message['error']}\n${message['stack']}'),
          );
        }
        break;
    }
  }

  /// Reset delivered FPS on each Start without reloading the interpreter.
  void beginSession() {
    _cadence
      ..reset()
      ..start();
  }

  Future<LocalYoloResult> detectNv21(CameraImage frame, int rotation) async {
    if (_disposed || _workerSend == null) {
      throw StateError('Local YOLO is not initialized');
    }
    if (frame.format.group != ImageFormatGroup.nv21 ||
        frame.planes.length != 1) {
      throw UnsupportedError(
        'Offline YOLO requires a single-plane NV21 CameraImage',
      );
    }
    if (_pending != null) {
      throw StateError('YOLO inference already in flight');
    }

    final plane = frame.planes.first;
    final pending = _PendingFrame(_nextFrameId++);
    _pending = pending;

    try {
      final transferWatch = Stopwatch()..start();
      final transferable = TransferableTypedData.fromList([plane.bytes]);
      pending.transferMs = transferWatch.elapsedMicroseconds / 1000;
      _workerSend!.send(
        _WorkerFrame(
          id: pending.id,
          nv21: transferable,
          width: frame.width,
          height: frame.height,
          rowStride: plane.bytesPerRow,
          rotation: rotation,
        ),
      );
    } catch (_) {
      if (identical(_pending, pending)) _pending = null;
      rethrow;
    }

    // A timeout cannot cancel a synchronous native invoke. Keep the slot busy
    // until its actual reply; never queue more frames or reload a slow model.
    pending.slowTimer = Timer(slowFrameThreshold, () {
      debugPrint(
        'OFFLINE SLOW frame_id=${pending.id} '
        'elapsed_ms=${pending.elapsed.elapsedMilliseconds} '
        'worker_retained=true frames_dropped_while_busy=true',
      );
    });
    final result = await pending.completer.future;
    _completedFrames++;
    if (!kReleaseMode &&
        (_completedFrames <= 5 || _completedFrames % 10 == 0)) {
      debugPrint(
        'OFFLINE PERF frame=$_completedFrames '
        'first_camera_frame=${result.isFirstFrame} '
        'preprocess_ms=${result.preprocessMs.toStringAsFixed(2)} '
        'input_copy_ms=${result.inputCopyMs.toStringAsFixed(2)} '
        'transfer_copy_ms=${result.transferMs.toStringAsFixed(3)} '
        'materialize_ms=${result.materializeMs.toStringAsFixed(3)} '
        'output_view_ms=${result.outputReadMs.toStringAsFixed(3)} '
        'inference_ms=${result.yoloMs.toStringAsFixed(2)} '
        'postprocess_ms=${result.postprocessMs.toStringAsFixed(2)} '
        'worker_total_ms=${result.workerMs.toStringAsFixed(2)} '
        'frame_total_ms=${result.processingMs.toStringAsFixed(2)} '
        'fps=${result.fps.toStringAsFixed(2)}',
      );
    }
    return result;
  }

  // Stop invalidates the caller but does not free the native in-flight slot.
  // The old frame drains in the worker and its result is discarded.
  void cancelPending() {
    final pending = _pending;
    pending?.slowTimer?.cancel();
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(const YoloRequestCancelled());
    }
  }

  Future<void> _teardown([Object? reason]) async {
    final isolate = _isolate;
    final receive = _receivePort;
    final errors = _errorPort;
    final subscription = _subscription;
    final errorSubscription = _errorSubscription;
    final ready = _ready;
    final pending = _pending;
    pending?.slowTimer?.cancel();

    _isolate = null;
    _workerSend = null;
    _receivePort = null;
    _errorPort = null;
    _subscription = null;
    _errorSubscription = null;
    _ready = null;
    _pending = null;

    isolate?.kill(priority: Isolate.immediate);
    await subscription?.cancel();
    await errorSubscription?.cancel();
    receive?.close();
    errors?.close();

    final error = reason ?? StateError('YOLO worker stopped');
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.completeError(error);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // If disposal races asset loading/spawn, let initialization settle before
    // closing the native interpreter in its owning isolate.
    try {
      await _starting;
    } catch (_) {}
    final worker = _workerSend;
    if (worker != null) {
      final ack = Completer<void>();
      _disposeAck = ack;
      try {
        worker.send('dispose');
        await ack.future.timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
    await _teardown(StateError('Local YOLO was disposed'));
  }
}
