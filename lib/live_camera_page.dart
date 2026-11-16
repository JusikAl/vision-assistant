import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kReleaseMode;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_config.dart';
import 'safety_tts_service.dart';
import 'voice_command_service.dart';
import 'wake_word_service.dart';
import 'services/detection_mode_manager.dart';
import 'services/local_yolo_service.dart';
import 'services/voice_command_parser.dart';
import 'services/performance_report.dart';

// ==========================================
// FRAME ENCODER ISOLATE
// ==========================================

void _encoderIsolateEntry(SendPort mainPort) {
  final receivePort = ReceivePort();

  mainPort.send(receivePort.sendPort);

  receivePort.listen((dynamic message) {
    try {
      final job = message as List<dynamic>;

      final data = (job[0] as TransferableTypedData)
          .materialize()
          .asUint8List();

      final width = job[1] as int;
      final height = job[2] as int;
      final stride = job[3] as int;
      final rotation = job[4] as int;

      const maxDimension = 960;

      final longestSide = width > height ? width : height;

      final scale = longestSide > maxDimension
          ? maxDimension / longestSide
          : 1.0;

      final targetWidth = (width * scale).round();
      final targetHeight = (height * scale).round();

      final image = img.Image(width: targetWidth, height: targetHeight);

      final uvStart = stride * height;

      for (int y = 0; y < targetHeight; y++) {
        final sourceY = y * height ~/ targetHeight;
        final yRow = sourceY * stride;
        final uvRow = uvStart + (sourceY ~/ 2) * stride;

        for (int x = 0; x < targetWidth; x++) {
          final sourceX = x * width ~/ targetWidth;

          final yIndex = yRow + sourceX;
          final uvIndex = uvRow + (sourceX ~/ 2) * 2;

          if (yIndex >= data.length || uvIndex + 1 >= data.length) {
            throw const FormatException('Invalid NV21 buffer');
          }

          final luma = data[yIndex];
          final v = data[uvIndex] - 128;
          final u = data[uvIndex + 1] - 128;

          final r = (luma + 1.402 * v).clamp(0, 255).toInt();

          final g = (luma - 0.344136 * u - 0.714136 * v).clamp(0, 255).toInt();

          final b = (luma + 1.772 * u).clamp(0, 255).toInt();

          image.setPixelRgb(x, y, r, g, b);
        }
      }

      final oriented = rotation == 0
          ? image
          : img.copyRotate(image, angle: rotation);

      final jpeg = Uint8List.fromList(img.encodeJpg(oriented, quality: 78));

      mainPort.send([true, jpeg]);
    } catch (error) {
      mainPort.send([false, error.toString()]);
    }
  });
}

// ==========================================
// FRAME ENCODER
// ==========================================

class _FrameEncoder {
  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receiveSubscription;

  SendPort? _sendPort;
  Completer<Uint8List>? _pending;
  Future<void>? _starting;

  bool _disposed = false;
  bool get isBusy => _pending != null;

  Future<void> start() {
    if (_disposed) {
      return Future.error(StateError('Encoder already disposed'));
    }

    return _starting ??= _initialize();
  }

  Future<void> _initialize() async {
    final ready = Completer<SendPort>();

    _receivePort = ReceivePort();

    _receiveSubscription = _receivePort!.listen((dynamic message) {
      if (message is SendPort) {
        if (!ready.isCompleted) {
          ready.complete(message);
        }
        return;
      }

      if (message is List && message.length == 2) {
        final request = _pending;
        _pending = null;

        if (request == null || request.isCompleted) {
          return;
        }

        if (message[0] == true) {
          request.complete(message[1] as Uint8List);
        } else {
          request.completeError(StateError(message[1].toString()));
        }
      }
    });

    _isolate = await Isolate.spawn<SendPort>(
      _encoderIsolateEntry,
      _receivePort!.sendPort,
    );

    _sendPort = await ready.future;
  }

  Future<Uint8List> encode(CameraImage frame, int rotation) {
    if (_disposed || _sendPort == null || _pending != null) {
      return Future.error(StateError('Encoder is unavailable'));
    }

    if (frame.format.group != ImageFormatGroup.nv21 ||
        frame.planes.length != 1) {
      return Future.error(UnsupportedError('Expected single-plane NV21'));
    }

    final pending = Completer<Uint8List>();
    _pending = pending;

    try {
      final plane = frame.planes.first;

      final payload = TransferableTypedData.fromList([plane.bytes]);

      _sendPort!.send([
        payload,
        frame.width,
        frame.height,
        plane.bytesPerRow,
        rotation,
      ]);
    } catch (error, stackTrace) {
      _pending = null;
      pending.completeError(error, stackTrace);
    }

    return pending.future;
  }

  void dispose() {
    _disposed = true;

    final pending = _pending;
    _pending = null;

    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Encoder disposed'));
    }

    unawaited(_receiveSubscription?.cancel());
    _receivePort?.close();

    _isolate?.kill(priority: Isolate.immediate);
    _sendPort = null;
  }
}

// ==========================================
// LIVE CAMERA PAGE
// ==========================================

class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({super.key});

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage>
    with WidgetsBindingObserver {
  CameraController? controller;

  WebSocketChannel? socket;
  StreamSubscription<dynamic>? subscription;

  Timer? responseTimeout;
  Timer? _wakeRestartTimer;

  final _encoder = _FrameEncoder();
  final DetectionModeManager _modeManager = DetectionModeManager();
  final LocalYoloService _localYolo = LocalYoloService();
  Timer? _reconnectTimer;
  bool _reconnecting = false;
  bool _offlineOnly = const bool.fromEnvironment('OFFLINE_ONLY');
  String _offlineModelStatus = 'loading';
  int _session = 0;
  Stopwatch? _detectStartup;
  bool _awaitingFirstResult = false;
  // One in-flight inference provides backpressure; avoid additional delay.
  static const int _offlineFrameIntervalMs = 60;
  double offlinePreprocessMs = 0;
  double offlinePostprocessMs = 0;

  final _performance = PerformanceReport();
  bool _speechOwnsAudio = false;
  int _voiceFailures = 0;

  final SafetyTtsService _safetyTts = SafetyTtsService();

  final VoiceCommandService _voiceCommands = VoiceCommandService();

  final WakeWordService _wakeWord = WakeWordService();

  bool _wakeModeEnabled = true;
  bool _wakeStarting = false;

  bool _commandStarted = false;

  bool voiceListening = false;
  bool processingVoiceCommand = false;

  String recognizedVoiceText = 'Ожидание «Hey Jarvis»';

  String lastVoiceReply = '';

  // ======================================
  // DETECTION STATE
  // ======================================

  bool running = false;
  bool waitingForResponse = false;
  bool stopping = false;
  bool starting = false;

  bool voiceEnabled = true;
  bool depthEnabled = false;

  String status = 'Initializing camera';
  String lastSafetyWarning = '';

  List<dynamic> detections = [];

  int imageWidth = 0;
  int imageHeight = 0;

  double processingMs = 0;
  double yoloMs = 0;
  double depthMs = 0;
  double fps = 0;

  DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime? lastResult;

  static const int frameIntervalMs = 100;

  String get serverUrl => AppConfig.wsDetectUrl;

  String get serverDebugAddress {
    try {
      return serverUrl;
    } catch (error) {
      return 'AppConfig не загружен: $error';
    }
  }

  // ======================================
  // INITIALIZATION
  // ======================================

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    _performance.start();
    AndroidCameraCameraX.analysisWidth = const int.fromEnvironment(
      'YOLO_ANALYSIS_WIDTH',
    );
    AndroidCameraCameraX.analysisHeight = const int.fromEnvironment(
      'YOLO_ANALYSIS_HEIGHT',
    );
    AndroidCameraCameraX.frameAdmission = _admitCameraFrame;
    AndroidCameraCameraX.frameProfile = kReleaseMode
        ? null
        : (metrics) {
            for (final metric in metrics.entries) {
              _performance.record(metric.key, metric.value.toDouble());
            }
          };
    _safetyTts.onSpeechStarted = (response, obstacle) {
      _performance.record('tts_response_ms', response);
      _performance.record('confirmed_to_speech_ms', obstacle);
    };
    _voiceCommands.onRecognitionMeasured = (milliseconds) =>
        _performance.record('voice_recognition_ms', milliseconds);
    _safetyTts.onSpeakingChanged = (speaking) async {
      _speechOwnsAudio = speaking;
      if (speaking) {
        _wakeRestartTimer?.cancel();
        await _voiceCommands.setSpeaking(true);
        await _wakeWord.stop();
        if (mounted) setState(() => voiceListening = false);
      } else {
        await _voiceCommands.setSpeaking(false);
        _scheduleWakeListening(const Duration(milliseconds: 350));
      }
    };

    initializeCamera();
    // Paint the first UI before asset loading; all native initialization and
    // warm-up run in the persistent YOLO worker, alongside camera setup.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_preloadLocalYolo());
    });

    unawaited(
      _safetyTts.initialize().then<void>(
        (_) {
          if (mounted) setState(() {});
        },
        onError: (Object error) {
          debugPrint('TTS initialization error: $error');
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> _preloadLocalYolo() async {
    try {
      await _localYolo.initialize();
      if (mounted) setState(() => _offlineModelStatus = 'ready');
    } catch (error) {
      debugPrint('OFFLINE PRELOAD ERROR: $error');
      if (mounted) setState(() => _offlineModelStatus = 'unavailable');
    }
  }

  void _logFirstDetectionResult(String mode) {
    if (!_awaitingFirstResult) return;
    _awaitingFirstResult = false;
    _performance.record(
      'detect_startup_ms',
      _detectStartup!.elapsedMicroseconds / 1000,
    );
    debugPrint(
      'DETECT PERF mode=$mode detect_startup_ms='
      '${(_detectStartup!.elapsedMicroseconds / 1000).toStringAsFixed(2)}',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _wakeModeEnabled = true;
      _safetyTts.setEnabled(voiceEnabled);

      if (controller?.value.isInitialized == true) {
        _scheduleWakeListening(const Duration(milliseconds: 800));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _wakeModeEnabled = false;
      _safetyTts.setEnabled(false);
      _wakeRestartTimer?.cancel();

      unawaited(_safetyTts.stop());
      unawaited(_voiceCommands.cancel());
      unawaited(_wakeWord.stop());

      voiceListening = false;
    }
  }

  // ======================================
  // CAMERA INITIALIZATION
  // ======================================

  Future<void> initializeCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        throw StateError('No cameras found');
      }

      final selected = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final camera = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );

      await camera.initialize();

      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);

      if (!mounted) {
        await camera.dispose();
        return;
      }

      setState(() {
        controller = camera;
        status = 'Camera ready';
      });

      _scheduleWakeListening(const Duration(milliseconds: 1200));
    } catch (error) {
      if (mounted) {
        setState(() {
          status = 'Camera error: $error';
        });
      }
    }
  }

  // ======================================
  // START DETECTION
  // ======================================

  Future<void> startDetection() async {
    final camera = controller;
    if (running ||
        stopping ||
        starting ||
        camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    starting = true;
    _safetyTts.resetScene();
    final session = ++_session;
    _detectStartup = Stopwatch()..start();
    _awaitingFirstResult = true;
    final wasPreloaded = _localYolo.isReady;
    setState(
      () => status = wasPreloaded
          ? 'Starting detection...'
          : 'Preparing offline YOLO...',
    );
    try {
      try {
        await _localYolo.initialize();
      } catch (error) {
        // Online remains available if the local asset/native runtime fails.
        debugPrint('Local YOLO unavailable at Start: $error');
        if (_offlineOnly) rethrow;
        final channel = await _modeManager.tryConnect(serverUrl);
        if (!mounted || session != _session) {
          unawaited(channel?.sink.close());
          return;
        }
        if (channel == null) rethrow;
        try {
          await _encoder.start();
        } catch (_) {
          unawaited(channel.sink.close());
          rethrow;
        }
        if (!mounted || session != _session) {
          unawaited(channel.sink.close());
          return;
        }
        _attachConnectedSocket(channel);
      }
      if (!mounted || (!_modeManager.isConnected && session != _session)) {
        return;
      }
      if (!_modeManager.isConnected) _modeManager.setOffline();
      _offlineModelStatus = _localYolo.isReady ? 'ready' : 'unavailable';
      running = true;
      waitingForResponse = false;
      _localYolo.beginSession();
      lastResult = null;
      lastSent = DateTime.fromMillisecondsSinceEpoch(0);

      await camera.startImageStream(processFrame);
      if (!mounted || !running) return;
      debugPrint(
        'DETECT PERF detect_stream_start_ms='
        '${(_detectStartup!.elapsedMicroseconds / 1000).toStringAsFixed(2)} '
        'preloaded=$wasPreloaded mode=${_modeManager.mode.name}',
      );
      if (_modeManager.isOffline) {
        _startReconnectTimer();
        // Server negotiation runs in parallel with working local detection.
        if (!_offlineOnly) unawaited(_reconnectIfPossible());
      }
      setState(() {
        status = _modeManager.isConnected
            ? 'Connected: YOLO + Depth'
            : 'OFFLINE: YOLO + voice warnings, no distance';
      });
    } catch (error) {
      await stopDetection(errorMessage: 'NO DETECTION: $error');
      if (voiceEnabled && mounted) {
        await _safetyTts.speakMessage('Внимание. Обнаружение недоступно.');
      }
    } finally {
      starting = false;
      if (mounted) setState(() {});
    }
  }

  void _attachConnectedSocket(WebSocketChannel channel) {
    _reconnectTimer?.cancel();
    ++_session;
    _safetyTts.resetScene();
    _localYolo.cancelPending();
    waitingForResponse = false;
    lastResult = null;
    _modeManager.setConnected();
    socket = channel;
    subscription = channel.stream.listen(
      (message) {
        if (identical(socket, channel)) onResult(message);
      },
      onError: (Object error) {
        if (identical(socket, channel)) {
          unawaited(_switchToOffline('Connection error: $error'));
        }
      },
      onDone: () {
        if (identical(socket, channel)) {
          unawaited(_switchToOffline('Server disconnected'));
        }
      },
    );
  }

  void _startReconnectTimer() {
    _reconnectTimer?.cancel();
    if (_offlineOnly) return;
    _reconnectTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_reconnectIfPossible()),
    );
  }

  Future<void> _reconnectIfPossible() async {
    if (_reconnecting ||
        !running ||
        stopping ||
        !_modeManager.isOffline ||
        _offlineOnly) {
      return;
    }
    _reconnecting = true;
    final session = _session;
    try {
      final channel = await _modeManager.tryConnect(serverUrl);
      if (channel == null) return;
      try {
        await _encoder.start();
      } catch (_) {
        unawaited(channel.sink.close());
        rethrow;
      }
      if (!mounted ||
          !running ||
          session != _session ||
          !_modeManager.isOffline ||
          stopping) {
        unawaited(channel.sink.close());
        return;
      }
      _attachConnectedSocket(channel);
      responseTimeout?.cancel();
      waitingForResponse = false;
      lastSent = DateTime.fromMillisecondsSinceEpoch(0);
      setState(() {
        detections = [];
        imageWidth = 0;
        imageHeight = 0;
        depthEnabled = false;
        status = 'Connected: server restored';
        lastSafetyWarning = '';
      });
    } catch (error) {
      debugPrint('Server reconnect error: $error');
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _switchToOffline(String reason) async {
    if (!running || stopping || !_modeManager.isConnected) return;
    _modeManager.setUnavailable();
    final session = ++_session;
    _safetyTts.resetScene();
    _localYolo.cancelPending();
    responseTimeout?.cancel();
    responseTimeout = null;
    waitingForResponse = false;

    final previousSubscription = subscription;
    final previousSocket = socket;
    subscription = null;
    socket = null;
    await previousSubscription?.cancel();
    try {
      await previousSocket?.sink.close().timeout(
        const Duration(milliseconds: 600),
      );
    } catch (_) {}

    if (!mounted || !running || stopping || session != _session) return;
    setState(() => status = 'Switching to offline: $reason');
    try {
      await _localYolo.initialize();
      if (!mounted || !running || stopping || session != _session) return;
      _modeManager.setOffline();
      _localYolo.beginSession();
      _startReconnectTimer();
      setState(() {
        detections = [];
        imageWidth = 0;
        imageHeight = 0;
        depthEnabled = false;
        depthMs = 0;
        processingMs = 0;
        yoloMs = 0;
        offlinePreprocessMs = 0;
        offlinePostprocessMs = 0;
        lastSafetyWarning = '';
        status = 'OFFLINE: YOLO + voice warnings, no distance';
      });
      if (voiceEnabled && mounted) {
        unawaited(
          _safetyTts.speakMessage(
            'Сервер недоступен. Включено локальное обнаружение без измерения расстояния.',
          ),
        );
      }
    } catch (error) {
      await stopDetection(errorMessage: 'NO DETECTION: $error');
      if (voiceEnabled && mounted) {
        await _safetyTts.speakMessage('Внимание. Обнаружение недоступно.');
      }
    }
  }

  // ======================================
  // FRAME PROCESSING
  // ======================================

  bool _admitCameraFrame() {
    // Count all analyzer callbacks, including those dropped before plane transfer.
    _performance.cameraFrame();
    if (!const bool.fromEnvironment('CAMERA_EARLY_DROP', defaultValue: true)) {
      return true;
    }
    return running &&
        !stopping &&
        (!_modeManager.isOffline ||
            (!waitingForResponse && !_localYolo.isBusy));
  }

  void processFrame(CameraImage frame) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _performance.cameraFrame();
    }
    if (!running || waitingForResponse || stopping) {
      return;
    }

    // Drop frames before copying NV21/JPEG. Cancellation never opens the
    // native slot until the actual old reply has drained.
    if (_modeManager.isOffline && _localYolo.isBusy) return;
    if (_modeManager.isConnected && _encoder.isBusy) return;
    final now = DateTime.now();

    final interval = _modeManager.isOffline
        ? _offlineFrameIntervalMs
        : frameIntervalMs;
    if (now.difference(lastSent).inMilliseconds < interval) return;

    waitingForResponse = true;
    lastSent = now;

    final sensorOrientation = controller?.description.sensorOrientation ?? 90;

    final rotation = frame.width > frame.height
        ? ((sensorOrientation % 360) + 360) % 360
        : 0;

    if (_modeManager.isOffline) {
      unawaited(_processOfflineFrame(frame, rotation));
    } else if (_modeManager.isConnected) {
      unawaited(_sendFrame(frame, rotation));
    } else {
      waitingForResponse = false;
    }
  }

  Future<void> _processOfflineFrame(CameraImage frame, int rotation) async {
    final session = _session;
    try {
      // Connected Mode continues using the original JPEG/WebSocket encoder.
      // Offline Mode reads NV21 directly and avoids the JPEG round-trip.
      final result = await _localYolo.detectNv21(frame, rotation);
      if (!mounted ||
          !running ||
          session != _session ||
          !_modeManager.isOffline ||
          stopping) {
        return;
      }
      _logFirstDetectionResult('offline');
      final alerts = _safetyTts.onDetections(
        detections: result.detections,
        imageWidth: result.imageWidth,
        imageHeight: result.imageHeight,
        frameAgeMs: result.processingMs,
      );
      _performance.record('inference_ms', result.yoloMs);
      _performance.record('preprocess_ms', result.preprocessMs);
      _performance.record('transfer_copy_ms', result.transferMs);
      _performance.record('materialize_ms', result.materializeMs);
      _performance.record('input_tensor_copy_ms', result.inputCopyMs);
      _performance.record('output_view_ms', result.outputReadMs);
      _performance.record('postprocess_ms', result.postprocessMs);
      _performance.record(
        'isolate_roundtrip_overhead_ms',
        result.processingMs - result.workerMs - result.transferMs,
      );
      _performance.record('safety_ms', _safetyTts.lastSafetyMs);
      _performance.yoloResult();
      final now = DateTime.now();
      final elapsed = lastResult == null
          ? _detectStartup?.elapsedMicroseconds ?? 0
          : now.difference(lastResult!).inMicroseconds;
      lastResult = now;
      setState(() {
        detections = result.detections;
        imageWidth = result.imageWidth;
        imageHeight = result.imageHeight;
        processingMs = result.processingMs;
        yoloMs = result.yoloMs;
        offlinePreprocessMs = result.preprocessMs;
        offlinePostprocessMs = result.postprocessMs;
        depthMs = 0;
        depthEnabled = false;
        fps = elapsed > 0 ? 1000000 / elapsed : 0;
        lastSafetyWarning = alerts.isEmpty ? '' : alerts.first.text;
      });
    } catch (error) {
      if (error is YoloRequestCancelled || session != _session) return;
      debugPrint('OFFLINE YOLO ERROR: $error');
      if (running && _modeManager.isOffline && !stopping) {
        await stopDetection(
          errorMessage: 'NO DETECTION: offline YOLO failed ($error)',
        );
        if (voiceEnabled && mounted) {
          await _safetyTts.speakMessage('Ошибка локального обнаружения.');
        }
      }
    } finally {
      if (session == _session && _modeManager.isOffline) {
        waitingForResponse = false;
      }
    }
  }

  Future<void> _sendFrame(CameraImage frame, int rotation) async {
    final session = _session;
    try {
      final jpeg = await _encoder.encode(frame, rotation);

      if (session != _session) return;
      if (!running || !_modeManager.isConnected || socket == null) {
        waitingForResponse = false;
        return;
      }

      socket!.sink.add(jpeg);

      responseTimeout?.cancel();

      responseTimeout = Timer(const Duration(seconds: 10), () {
        if (running) {
          unawaited(_switchToOffline('Server response timeout'));
        }
      });
    } catch (error) {
      if (session != _session) return;
      debugPrint('Frame processing error: $error');
      waitingForResponse = false;
      if (running && _modeManager.isConnected && !stopping) {
        unawaited(_switchToOffline('Camera/frame encoding error: $error'));
      }
    }
  }

  // ======================================
  // SERVER RESPONSE
  // ======================================

  void onResult(dynamic message) {
    if (!mounted || !running || !_modeManager.isConnected) return;

    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      if (!data.containsKey('detections')) return;
      _logFirstDetectionResult('connected');

      responseTimeout?.cancel();
      responseTimeout = null;

      final frameDetections = data['detections'] as List<dynamic>? ?? [];
      final frameWidth = (data['image_width'] as num?)?.toInt() ?? 0;
      final frameHeight = (data['image_height'] as num?)?.toInt() ?? 0;
      // Same visual policy and same speaker in both modes. Do not forward
      // arbitrary server prose or experimental distance_m values to speech.
      final alerts = _safetyTts.onDetections(
        detections: frameDetections,
        imageWidth: frameWidth,
        imageHeight: frameHeight,
        allowReliableDepth: data['depth_enabled'] == true,
        frameAgeMs: DateTime.now().difference(lastSent).inMicroseconds / 1000,
      );
      _performance.yoloResult();
      _performance.record('safety_ms', _safetyTts.lastSafetyMs);
      final currentWarning = alerts.isEmpty ? '' : alerts.first.text;

      final now = DateTime.now();
      var currentFps = 0.0;

      if (lastResult != null) {
        final elapsed = now.difference(lastResult!).inMicroseconds;

        if (elapsed > 0) {
          currentFps = 1000000 / elapsed;
        }
      }

      lastResult = now;

      setState(() {
        detections = frameDetections;

        lastSafetyWarning = currentWarning;

        imageWidth = frameWidth;

        imageHeight = frameHeight;

        processingMs = (data['processing_ms'] as num?)?.toDouble() ?? 0;

        yoloMs = (data['yolo_ms'] as num?)?.toDouble() ?? 0;

        depthMs = (data['depth_ms'] as num?)?.toDouble() ?? 0;

        depthEnabled = data['depth_enabled'] == true;

        fps = currentFps;
      });
    } catch (error) {
      debugPrint('Response error: $error');
    } finally {
      waitingForResponse = false;
    }
  }

  // ======================================
  // WAKE WORD LISTENING
  // ======================================

  void _scheduleWakeListening([
    Duration delay = const Duration(milliseconds: 1200),
  ]) {
    if (!mounted ||
        !_wakeModeEnabled ||
        _speechOwnsAudio ||
        processingVoiceCommand) {
      return;
    }

    _wakeRestartTimer?.cancel();

    _wakeRestartTimer = Timer(delay, () {
      if (mounted) {
        unawaited(_startWakeListening());
      }
    });
  }

  Future<void> _startWakeListening() async {
    if (!mounted ||
        !_wakeModeEnabled ||
        _speechOwnsAudio ||
        _wakeStarting ||
        voiceListening ||
        processingVoiceCommand) {
      return;
    }

    _wakeStarting = true;

    try {
      await _wakeWord.start(
        onDetected: _onWakeDetected,
        onError: (error) {
          debugPrint('WAKE ERROR: $error');

          if (!mounted || !_wakeModeEnabled) {
            return;
          }

          _wakeModeEnabled = false;

          setState(() {
            voiceListening = false;
            recognizedVoiceText = 'Wake word ошибка: $error';
          });
        },
      );

      if (!mounted || !_wakeModeEnabled) {
        await _wakeWord.stop();
        return;
      }

      setState(() {
        voiceListening = true;
        recognizedVoiceText = 'Ожидание «Hey Jarvis»';
      });
    } catch (error) {
      debugPrint('WAKE START ERROR: $error');

      if (mounted) {
        _wakeModeEnabled = false;

        setState(() {
          voiceListening = false;
          recognizedVoiceText = 'Wake word не запущен: $error';
        });
      }
    } finally {
      _wakeStarting = false;
    }
  }

  // ======================================
  // WAKE WORD DETECTED
  // ======================================

  Future<void> _onWakeDetected() async {
    if (!mounted ||
        !_wakeModeEnabled ||
        _speechOwnsAudio ||
        processingVoiceCommand) {
      return;
    }

    processingVoiceCommand = true;
    _commandStarted = false;

    _wakeRestartTimer?.cancel();

    setState(() {
      voiceListening = false;
      recognizedVoiceText = 'Hey Jarvis обнаружено. Скажите команду';
    });

    try {
      await _voiceCommands.listen(
        onResult: (text) {
          if (!mounted || !_wakeModeEnabled) return;

          _commandStarted = true;
          _voiceFailures = 0;

          setState(() {
            recognizedVoiceText = 'Команда: $text';
          });

          unawaited(_runCommandAndResume(text));
        },
        onPartial: (text) {
          if (!mounted || !_wakeModeEnabled) return;

          setState(() {
            recognizedVoiceText = 'Слышу: $text';
          });
        },
        onError: (message) {
          debugPrint('COMMAND STT ERROR: $message');
          if (++_voiceFailures >= 3) _wakeModeEnabled = false;

          if (!mounted || !_wakeModeEnabled) return;

          setState(() {
            recognizedVoiceText = 'Распознавание: $message';
          });
        },
        onDone: () {
          if (!_commandStarted) {
            unawaited(_resumeWakeAfterCommand());
          }
        },
      );
    } catch (error) {
      debugPrint('COMMAND ERROR: $error');

      await _resumeWakeAfterCommand();
    }
  }

  // ======================================
  // EXECUTE COMMAND AND RESUME
  // ======================================

  Future<void> _runCommandAndResume(String text) async {
    _commandStarted = true;

    try {
      await _executeVoiceCommand(text);
    } finally {
      await _resumeWakeAfterCommand();
    }
  }

  Future<void> _resumeWakeAfterCommand() async {
    if (!mounted || !processingVoiceCommand) {
      return;
    }

    _commandStarted = false;

    setState(() {
      processingVoiceCommand = false;
    });

    if (_wakeModeEnabled) {
      _scheduleWakeListening(
        Duration(milliseconds: 900 * (1 << _voiceFailures.clamp(0, 3))),
      );
    }
  }

  // ======================================
  // VOICE COMMAND PROCESSING
  // ======================================

  Future<void> _executeVoiceCommand(String transcript) async {
    try {
      final command = VoiceCommandParser.normalize(transcript);
      final intent = VoiceCommandParser.parse(command);

      String reply;

      if (_hasAny(command, ['выключи', 'отключи', 'убери']) &&
          _hasAny(command, ['предупрежден', 'озвуч', 'голос', 'звук'])) {
        _safetyTts.setEnabled(false);

        if (mounted) {
          setState(() => voiceEnabled = false);
        }

        reply = 'Автоматические предупреждения выключены';
      } else if (_hasAny(command, ['включи', 'верни']) &&
          _hasAny(command, ['предупрежден', 'озвуч', 'голос', 'звук'])) {
        _safetyTts.setEnabled(true);

        if (mounted) {
          setState(() => voiceEnabled = true);
        }

        reply = 'Автоматические предупреждения включены';
      } else if (intent == VoiceCommand.describe) {
        reply = _describeDetectedObjects();
      } else if (_hasAny(command, [
        'повтори',
        'повторить',
        'еще раз',
        'скажи снова',
      ])) {
        reply = lastVoiceReply.isNotEmpty
            ? lastVoiceReply
            : lastSafetyWarning.isNotEmpty
            ? lastSafetyWarning
            : 'Пока нечего повторять';
      } else if (_hasAny(command, ['помощь', 'команды', 'подсказка'])) {
        reply =
            'После Hey Jarvis скажите: '
            'начать, остановить, что впереди, '
            'повтори, включи предупреждения '
            'или выключи предупреждения';
      } else if (intent == VoiceCommand.stop) {
        if (running) {
          await stopDetection();
        }

        reply = 'Обнаружение остановлено';
      } else if (intent == VoiceCommand.start) {
        if (!running) {
          await startDetection();
        }

        reply = running
            ? 'Обнаружение запущено'
            : 'Не удалось запустить обнаружение';
      } else {
        reply =
            'Команда не распознана. '
            'Скажите: помощь';
      }

      if (!mounted) return;

      if (!_hasAny(command, [
        'повтори',
        'повторить',
        'еще раз',
        'скажи снова',
      ])) {
        lastVoiceReply = reply;
      }

      await _safetyTts.speakMessage(reply);
    } catch (error) {
      debugPrint('Voice command failed: $error');

      if (mounted) {
        await _safetyTts.speakMessage('Ошибка выполнения команды');
      }
    }
  }

  bool _hasAny(String text, List<String> phrases) {
    return phrases.any(text.contains);
  }

  // ======================================
  // OBJECT DESCRIPTION
  // ======================================

  String _describeDetectedObjects() {
    if (!running) {
      return 'Обнаружение выключено. '
          'Скажите Hey Jarvis, затем начать';
    }

    if (detections.isEmpty || imageWidth <= 0) {
      return 'Камера сейчас не обнаружила объектов';
    }

    const names = <String, String>{
      'bike': 'велосипед',
      'building': 'здание',
      'car': 'автомобиль',
      'person': 'человек',
      'stairs': 'лестница',
      'traffic sign': 'дорожный знак',
      'electrical pole': 'столб',
      'road': 'дорога',
      'motorcycle': 'мотоцикл',
      'dustbin': 'мусорный бак',
      'dog': 'собака',
      'manhole': 'люк',
      'tree': 'дерево',
      'guard rail': 'ограждение',
      'pedestrian crosswalk': 'пешеходный переход',
      'truck': 'грузовик',
      'bus': 'автобус',
      'bench': 'скамейка',
      'traffic cone': 'дорожный конус',
      'fire hydrant': 'гидрант',
      'teraffic barrel': 'дорожный барьер',
      'plant pot': 'горшок с растением',
      'electrical box': 'электрический шкаф',
      'chair': 'стул',
      'bicycle rack': 'велосипедная стойка',
    };

    final visible = <String>{};

    for (final detection in detections) {
      if (detection is! Map) continue;

      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0;

      if (confidence < 0.40) continue;

      final bbox = detection['bbox'];

      if (bbox is! List ||
          bbox.length != 4 ||
          bbox.any((value) => value is! num)) {
        continue;
      }

      final cx =
          ((bbox[0] as num).toDouble() + (bbox[2] as num).toDouble()) /
          (2 * imageWidth);

      if (cx < 0.20 || cx > 0.80) continue;

      final name = detection['class_name']?.toString().toLowerCase() ?? '';

      final russian = names[name];

      if (russian != null) {
        visible.add(russian);
      }

      if (visible.length >= 4) break;
    }

    if (visible.isEmpty) {
      return 'В центральной части кадра '
          'объекты не обнаружены';
    }

    return 'Камера видит: ${visible.join(', ')}';
  }

  // ======================================
  // STOP DETECTION
  // ======================================

  Future<void> stopDetection({String? errorMessage}) async {
    if (stopping) return;

    stopping = true;
    ++_session;
    _awaitingFirstResult = false;
    _localYolo.cancelPending();
    _reconnectTimer?.cancel();
    _modeManager.setUnavailable();
    running = false;
    waitingForResponse = false;

    responseTimeout?.cancel();
    responseTimeout = null;

    await _safetyTts.stop();

    try {
      await subscription?.cancel();
      subscription = null;

      final camera = controller;

      if (camera != null && camera.value.isStreamingImages) {
        await camera.stopImageStream();
      }

      await socket?.sink.close().timeout(const Duration(milliseconds: 600));
      socket = null;
    } catch (error) {
      debugPrint('Stop error: $error');
    } finally {
      stopping = false;

      if (mounted) {
        setState(() {
          detections = [];
          lastSafetyWarning = '';

          imageWidth = 0;
          imageHeight = 0;

          processingMs = 0;
          yoloMs = 0;
          offlinePreprocessMs = 0;
          offlinePostprocessMs = 0;
          depthMs = 0;
          fps = 0;

          depthEnabled = false;
          status = errorMessage ?? 'Stopped';
        });
      }
    }
  }

  // ======================================
  // CAMERA PREVIEW
  // ======================================

  Widget buildCameraPreview() {
    final camera = controller;

    if (camera == null || !camera.value.isInitialized) {
      if (status.startsWith('Camera error')) {
        return Center(child: Text(status, textAlign: TextAlign.center));
      }

      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: CameraPreview(
        camera,
        child: CustomPaint(
          painter: LiveDetectionPainter(
            detections: detections,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
          ),
        ),
      ),
    );
  }

  // ======================================
  // MANUAL WAKE WORD RESTART
  // ======================================

  Future<void> _restartWakeWord() async {
    if (processingVoiceCommand) return;
    _voiceFailures = 0;

    _wakeRestartTimer?.cancel();
    _wakeModeEnabled = false;

    await _wakeWord.stop();

    if (!mounted) return;

    setState(() {
      voiceListening = false;
      _wakeModeEnabled = true;
      recognizedVoiceText = 'Перезапуск wake word...';
    });

    _scheduleWakeListening(const Duration(milliseconds: 400));
  }

  // ======================================
  // USER INTERFACE
  // ======================================

  @override
  Widget build(BuildContext context) {
    final cameraReady = controller?.value.isInitialized == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Navigation Assistant'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: buildCameraPreview()),

            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('Status: $status', textAlign: TextAlign.center),
                  Text('Offline YOLO: $_offlineModelStatus'),
                  if (voiceEnabled && !_safetyTts.offlineVoiceReady)
                    Text(
                      _safetyTts.lastError == null
                          ? 'Подготовка голоса…'
                          : 'Голосовые предупреждения недоступны. Проверьте '
                                'русский офлайн-голос в настройках синтеза речи Android.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.orange),
                    ),

                  Text(
                    _modeManager.isOffline
                        ? 'MODE: OFFLINE · Visual warnings · Distance unavailable'
                        : _modeManager.isConnected
                        ? 'MODE: CONNECTED'
                        : 'MODE: NO DETECTION',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _modeManager.isOffline ? Colors.orange : null,
                    ),
                  ),

                  Text(
                    'WebSocket: $serverDebugAddress',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'Objects: ${detections.length} | '
                    'FPS: ${fps.toStringAsFixed(1)}',
                  ),

                  const SizedBox(height: 4),

                  Text(
                    _modeManager.isOffline
                        ? 'Offline total: ${processingMs.toStringAsFixed(0)} ms | '
                              'Prep: ${offlinePreprocessMs.toStringAsFixed(0)} ms | '
                              'YOLO: ${yoloMs.toStringAsFixed(0)} ms | '
                              'Post: ${offlinePostprocessMs.toStringAsFixed(0)} ms'
                        : 'Server: ${processingMs.toStringAsFixed(0)} ms | '
                              'YOLO: ${yoloMs.toStringAsFixed(0)} ms | '
                              'Depth: ${depthEnabled ? '${depthMs.toStringAsFixed(0)} ms' : 'off'}',
                    textAlign: TextAlign.center,
                  ),

                  if (imageWidth > 0 && imageHeight > 0) ...[
                    const SizedBox(height: 4),

                    Text(
                      'Frame: '
                      '$imageWidth x $imageHeight',
                    ),
                  ],

                  const SizedBox(height: 8),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Только Offline YOLO (для проверки)'),
                    subtitle: const Text('Сервер не используется'),
                    value: _offlineOnly,
                    onChanged: running || starting || stopping
                        ? null
                        : (value) => setState(() => _offlineOnly = value),
                  ),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Голосовые предупреждения'),
                    subtitle: const Text('YOLO Safety Assistant'),
                    secondary: const Icon(Icons.record_voice_over),
                    value: voiceEnabled,
                    onChanged: (value) {
                      _safetyTts.setEnabled(value);

                      setState(() {
                        voiceEnabled = value;
                      });
                    },
                  ),

                  if (lastSafetyWarning.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        lastSafetyWarning,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),

                  const SizedBox(height: 8),

                  const Text(
                    'Голосовое управление: '
                    '«Hey Jarvis», затем команда',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),

                  const SizedBox(height: 8),

                  if (recognizedVoiceText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        recognizedVoiceText,
                        maxLines: 3,
                        textAlign: TextAlign.center,
                      ),
                    ),

                  const SizedBox(height: 8),

                  OutlinedButton.icon(
                    onPressed: processingVoiceCommand ? null : _restartWakeWord,
                    icon: const Icon(Icons.mic),
                    label: const Text('Перезапустить wake word'),
                  ),

                  const SizedBox(height: 8),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: !cameraReady || stopping || starting
                          ? null
                          : running
                          ? () => stopDetection()
                          : startDetection,
                      icon: Icon(running ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        running ? 'Stop Detection' : 'Start Detection',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ======================================
  // CLEANUP
  // ======================================

  @override
  void dispose() {
    ++_session;
    running = false;

    responseTimeout?.cancel();

    WidgetsBinding.instance.removeObserver(this);

    _wakeModeEnabled = false;
    _wakeRestartTimer?.cancel();

    AndroidCameraCameraX.frameAdmission = null;
    AndroidCameraCameraX.frameProfile = null;
    AndroidCameraCameraX.analysisWidth = AndroidCameraCameraX.analysisHeight =
        0;
    _performance.dispose();
    _safetyTts.onSpeakingChanged = null;
    _safetyTts.onSpeechStarted = null;
    _voiceCommands.onRecognitionMeasured = null;
    unawaited(_voiceCommands.dispose());
    unawaited(_wakeWord.dispose());

    unawaited(subscription?.cancel());
    unawaited(socket?.sink.close());

    unawaited(controller?.dispose());

    _encoder.dispose();
    _reconnectTimer?.cancel();
    unawaited(_localYolo.dispose());

    unawaited(_safetyTts.dispose());

    super.dispose();
  }
}

// ==========================================
// DETECTION PAINTER
// ==========================================

class LiveDetectionPainter extends CustomPainter {
  final List<dynamic> detections;

  final int imageWidth;
  final int imageHeight;

  LiveDetectionPainter({
    required this.detections,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        size.width <= 0 ||
        size.height <= 0) {
      return;
    }

    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(imageWidth.toDouble(), imageHeight.toDouble()),
      size,
    );

    final destination = fitted.destination;

    final scaleX = destination.width / imageWidth;

    final scaleY = destination.height / imageHeight;

    final offsetX = (size.width - destination.width) / 2;

    final offsetY = (size.height - destination.height) / 2;

    final boxPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    final labelBackground = Paint()
      ..color = Colors.green.shade800
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    for (final item in detections) {
      if (item is! Map) continue;

      final bbox = item['bbox'];

      if (bbox is! List || bbox.length < 4) {
        continue;
      }

      if (bbox.take(4).any((value) => value is! num)) {
        continue;
      }

      final x1 = (bbox[0] as num).toDouble() * scaleX + offsetX;

      final y1 = (bbox[1] as num).toDouble() * scaleY + offsetY;

      final x2 = (bbox[2] as num).toDouble() * scaleX + offsetX;

      final y2 = (bbox[3] as num).toDouble() * scaleY + offsetY;

      final rect = Rect.fromLTRB(x1, y1, x2, y2);

      canvas.drawRect(rect, boxPaint);

      final name = item['class_name']?.toString() ?? 'Object';

      final confidence = (item['confidence'] as num?)?.toDouble() ?? 0;

      final distance = (item['distance_m'] as num?)?.toDouble();

      final validDistance =
          distance != null && distance.isFinite && distance > 0;

      final label =
          '$name '
          '${(confidence * 100).toStringAsFixed(0)}%'
          '${validDistance ? ' · ${distance.toStringAsFixed(2)} m' : ''}';

      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '...',
      )..layout(maxWidth: size.width > 12 ? size.width - 12 : size.width);

      final labelWidth = textPainter.width + 12;

      final labelHeight = textPainter.height + 8;

      final labelX = x1
          .clamp(0.0, (size.width - labelWidth).clamp(0.0, size.width))
          .toDouble();

      final preferredY = y1 - labelHeight;

      final labelY = preferredY >= 0
          ? preferredY
          : y1
                .clamp(0.0, (size.height - labelHeight).clamp(0.0, size.height))
                .toDouble();

      final labelRect = Rect.fromLTWH(labelX, labelY, labelWidth, labelHeight);

      canvas.drawRRect(
        RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
        labelBackground,
      );

      textPainter.paint(canvas, Offset(labelX + 6, labelY + 4));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LiveDetectionPainter old) {
    return old.imageWidth != imageWidth ||
        old.imageHeight != imageHeight ||
        old.detections != detections;
  }
}
