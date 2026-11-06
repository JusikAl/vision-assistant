import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

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

    _receiveSubscription?.cancel();
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

class _LiveCameraPageState extends State<LiveCameraPage> {
  CameraController? controller;
  WebSocketChannel? socket;
  StreamSubscription<dynamic>? subscription;
  Timer? responseTimeout;

  final _encoder = _FrameEncoder();

  bool running = false;
  bool waitingForResponse = false;
  bool stopping = false;

  String status = 'Initializing camera';

  List<dynamic> detections = [];

  int imageWidth = 0;
  int imageHeight = 0;

  double processingMs = 0;
  double yoloMs = 0;
  double depthMs = 0;
  double fps = 0;

  bool depthEnabled = false;

  DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime? lastResult;

  // CHANGE IP IF YOUR PC ADDRESS CHANGES
  static const serverUrl = 'ws://192.168.10.3:8000/ws/detect';

  static const frameIntervalMs = 100;

  @override
  void initState() {
    super.initState();
    initializeCamera();
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

    if (running || stopping || camera == null || !camera.value.isInitialized) {
      return;
    }

    setState(() {
      status = 'Connecting...';
    });

    try {
      await _encoder.start();

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
          stopDetection(errorMessage: 'Connection error: $error');
        },
        onDone: () {
          stopDetection(errorMessage: 'Server disconnected');
        },
      );

      await camera.startImageStream(processFrame);

      if (mounted && running) {
        setState(() {
          status = 'Detecting';
        });
      }
    } catch (error) {
      await stopDetection(errorMessage: 'Start failed: $error');
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

    _sendFrame(frame, rotation);
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
          stopDetection(errorMessage: 'Server response timeout');
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
    responseTimeout?.cancel();
    responseTimeout = null;

    if (!mounted || !running) {
      return;
    }

    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

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
  // STOP DETECTION
  // ======================================

  Future<void> stopDetection({String? errorMessage}) async {
    if (stopping) return;

    stopping = true;
    running = false;
    waitingForResponse = false;

    responseTimeout?.cancel();
    responseTimeout = null;

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

          imageWidth = 0;
          imageHeight = 0;

          processingMs = 0;
          yoloMs = 0;
          depthMs = 0;
          depthEnabled = false;
          fps = 0;

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
  // UI
  // ======================================

  @override
  Widget build(BuildContext context) {
    final cameraReady = controller?.value.isInitialized == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('YOLO + Depth Live Detection'),
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

                  const SizedBox(height: 8),

                  Text(
                    'Objects: ${detections.length} | '
                    'Result FPS: ${fps.toStringAsFixed(1)}',
                  ),

                  const SizedBox(height: 4),

                  Text(
                    'Server: ${processingMs.toStringAsFixed(0)} ms | '
                    'YOLO: ${yoloMs.toStringAsFixed(0)} ms | '
                    'Depth: ${depthEnabled ? '${depthMs.toStringAsFixed(0)} ms' : 'off'}',
                  ),

                  if (imageWidth > 0 && imageHeight > 0) ...[
                    const SizedBox(height: 4),

                    Text('Frame: $imageWidth x $imageHeight'),
                  ],

                  const SizedBox(height: 12),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: !cameraReady || stopping
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

  @override
  void dispose() {
    running = false;

    responseTimeout?.cancel();
    subscription?.cancel();

    socket?.sink.close();
    controller?.dispose();

    _encoder.dispose();

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

      final x1 = (bbox[0] as num).toDouble() * scaleX + offsetX;

      final y1 = (bbox[1] as num).toDouble() * scaleY + offsetY;

      final x2 = (bbox[2] as num).toDouble() * scaleX + offsetX;

      final y2 = (bbox[3] as num).toDouble() * scaleY + offsetY;

      final rect = Rect.fromLTRB(x1, y1, x2, y2);

      canvas.drawRect(rect, boxPaint);

      final name = item['class_name']?.toString() ?? 'Object';

      final confidence = (item['confidence'] as num?)?.toDouble() ?? 0;

      // Distance from FastAPI
      final distance = (item['distance_m'] as num?)?.toDouble();

      final validDistance =
          distance != null && distance.isFinite && distance > 0;

      final label =
          '$name ${(confidence * 100).toStringAsFixed(0)}%'
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
