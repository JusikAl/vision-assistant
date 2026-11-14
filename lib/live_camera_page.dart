import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'app_config.dart';
import 'safety_tts_service.dart';
import 'voice_command_service.dart';
import 'wake_word_service.dart';

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

    initializeCamera();

    _safetyTts.initialize().catchError((Object error) {
      debugPrint('TTS initialization error: $error');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _wakeModeEnabled = true;

      if (controller?.value.isInitialized == true) {
        _scheduleWakeListening(const Duration(milliseconds: 800));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _wakeModeEnabled = false;
      _wakeRestartTimer?.cancel();

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

    setState(() {
      status = 'Connecting...';
    });

    try {
      await _encoder.start();

      debugPrint('WS CONNECT: $serverUrl');

      final channel = WebSocketChannel.connect(Uri.parse(serverUrl));

      await channel.ready.timeout(const Duration(seconds: 8));

      if (!mounted) {
        await channel.sink.close();
        return;
      }

      socket = channel;
      running = true;
      waitingForResponse = false;
      lastResult = null;

      lastSent = DateTime.fromMillisecondsSinceEpoch(0);

      subscription = channel.stream.listen(
        onResult,
        onError: (Object error) {
          unawaited(stopDetection(errorMessage: 'Connection error: $error'));
        },
        onDone: () {
          unawaited(stopDetection(errorMessage: 'Server disconnected'));
        },
      );

      await camera.startImageStream(processFrame);

      if (mounted && running) {
        setState(() {
          status = 'Detecting';
        });
      }
    } catch (error) {
      await stopDetection(
        errorMessage: 'Start failed ($serverDebugAddress): $error',
      );
    } finally {
      starting = false;

      if (mounted) setState(() {});
    }
  }

  // ======================================
  // FRAME PROCESSING
  // ======================================

  void processFrame(CameraImage frame) {
    if (!running || waitingForResponse || stopping) {
      return;
    }

    final now = DateTime.now();

    if (now.difference(lastSent).inMilliseconds < frameIntervalMs) {
      return;
    }

    waitingForResponse = true;
    lastSent = now;

    final sensorOrientation = controller?.description.sensorOrientation ?? 90;

    final rotation = frame.width > frame.height
        ? ((sensorOrientation % 360) + 360) % 360
        : 0;

    unawaited(_sendFrame(frame, rotation));
  }

  Future<void> _sendFrame(CameraImage frame, int rotation) async {
    try {
      final jpeg = await _encoder.encode(frame, rotation);

      if (!running || socket == null) {
        waitingForResponse = false;
        return;
      }

      socket!.sink.add(jpeg);

      responseTimeout?.cancel();

      responseTimeout = Timer(const Duration(seconds: 10), () {
        if (running) {
          unawaited(stopDetection(errorMessage: 'Server response timeout'));
        }
      });
    } catch (error) {
      debugPrint('Frame processing error: $error');

      waitingForResponse = false;
    }
  }

  // ======================================
  // SERVER RESPONSE
  // ======================================

  void onResult(dynamic message) {
    if (!mounted || !running) return;

    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      if (!data.containsKey('detections')) return;

      responseTimeout?.cancel();
      responseTimeout = null;

      final safetyAlerts = data['safety_alerts'] as List<dynamic>? ?? [];

      // Safety warnings stay independent of
      // the wake-word recognizer.
      if (voiceEnabled) {
        _safetyTts.onFrame(safetyAlerts);
      }

      String currentWarning = '';

      if (safetyAlerts.isNotEmpty && safetyAlerts.first is Map) {
        currentWarning = (safetyAlerts.first as Map)['text']?.toString() ?? '';
      }

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
        detections = data['detections'] as List<dynamic>? ?? [];

        lastSafetyWarning = currentWarning;

        imageWidth = (data['image_width'] as num?)?.toInt() ?? 0;

        imageHeight = (data['image_height'] as num?)?.toInt() ?? 0;

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
    if (!mounted || !_wakeModeEnabled || processingVoiceCommand) {
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
    if (!mounted || !_wakeModeEnabled || processingVoiceCommand) {
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
      _scheduleWakeListening(const Duration(milliseconds: 900));
    }
  }

  // ======================================
  // VOICE COMMAND PROCESSING
  // ======================================

  Future<void> _executeVoiceCommand(String transcript) async {
    try {
      final command = transcript
          .toLowerCase()
          .replaceAll(RegExp(r'[^а-яёa-z0-9\s]'), '')
          .trim();

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
      } else if (_hasAny(command, [
        'что впереди',
        'что рядом',
        'что вокруг',
        'что ты видишь',
        'что видишь',
        'опиши',
      ])) {
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
      } else if (_hasAny(command, [
        'останови',
        'остановить',
        'стоп',
        'заверши обнаружение',
        'выключи камеру',
      ])) {
        if (running) {
          await stopDetection();
        }

        reply = 'Обнаружение остановлено';
      } else if (_hasAny(command, [
        'начни',
        'начать',
        'запусти',
        'запустить',
        'включи камеру',
      ])) {
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

      await socket?.sink.close();
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
                    'Server: '
                    '${processingMs.toStringAsFixed(0)} ms | '
                    'YOLO: ${yoloMs.toStringAsFixed(0)} ms | '
                    'Depth: '
                    '${depthEnabled ? '${depthMs.toStringAsFixed(0)} ms' : 'off'}',
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
    running = false;

    responseTimeout?.cancel();

    WidgetsBinding.instance.removeObserver(this);

    _wakeModeEnabled = false;
    _wakeRestartTimer?.cancel();

    unawaited(_voiceCommands.dispose());
    unawaited(_wakeWord.dispose());

    unawaited(subscription?.cancel());
    unawaited(socket?.sink.close());

    unawaited(controller?.dispose());

    _encoder.dispose();

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
