import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

class LiveCameraPage extends StatefulWidget {
  const LiveCameraPage({super.key});

  @override
  State<LiveCameraPage> createState() => _LiveCameraPageState();
}

class _LiveCameraPageState extends State<LiveCameraPage> {
  CameraController? controller;
  WebSocketChannel? socket;
  StreamSubscription? subscription;

  bool running = false;
  bool waitingForResponse = false;
  bool stopping = false;

  String status = 'Initializing camera';

  List<dynamic> detections = [];

  int imageWidth = 0;
  int imageHeight = 0;

  double processingMs = 0;
  double fps = 0;

  DateTime lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime? lastResult;

  static const String serverUrl = 'ws://192.168.8.57:8000/ws/detect';

  static const int frameIntervalMs = 250;

  @override
  void initState() {
    super.initState();
    initializeCamera();
  }

  Future<void> initializeCamera() async {
    try {
      final cameras = await availableCameras();

      if (cameras.isEmpty) {
        throw Exception('No cameras found');
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
    } catch (e) {
      debugPrint('Camera initialization error: $e');

      if (mounted) {
        setState(() {
          status = 'Camera error: $e';
        });
      }
    }
  }

  Future<void> startDetection() async {
    final camera = controller;

    if (running || stopping || camera == null || !camera.value.isInitialized) {
      return;
    }

    setState(() {
      status = 'Connecting to YOLO server...';
    });

    try {
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
        onError: (error) {
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
    } catch (e) {
      debugPrint('Start detection error: $e');

      await stopDetection(errorMessage: 'Start failed: $e');
    }
  }

  void onResult(dynamic message) {
    if (!mounted || !running) return;

    try {
      final data = jsonDecode(message as String) as Map<String, dynamic>;

      final now = DateTime.now();

      double currentFps = 0;

      if (lastResult != null) {
        final elapsed = now.difference(lastResult!).inMicroseconds;

        if (elapsed > 0) {
          currentFps = 1000000 / elapsed;
        }
      }

      lastResult = now;

      setState(() {
        detections = data['detections'] ?? [];

        imageWidth = (data['image_width'] as num?)?.toInt() ?? 0;

        imageHeight = (data['image_height'] as num?)?.toInt() ?? 0;

        processingMs = (data['processing_ms'] as num?)?.toDouble() ?? 0;

        fps = currentFps;
      });
    } catch (e) {
      debugPrint('YOLO response error: $e');
    } finally {
      waitingForResponse = false;
    }
  }

  void processFrame(CameraImage frame) {
    if (!running || waitingForResponse) {
      return;
    }

    final now = DateTime.now();

    if (now.difference(lastSent).inMilliseconds < frameIntervalMs) {
      return;
    }

    waitingForResponse = true;
    lastSent = now;

    try {
      final jpegBytes = convertFrame(frame);

      if (running && socket != null) {
        socket!.sink.add(jpegBytes);
      } else {
        waitingForResponse = false;
      }
    } catch (e) {
      debugPrint('Frame conversion error: $e');

      waitingForResponse = false;
    }
  }

  Uint8List convertFrame(CameraImage frame) {
    if (frame.format.group != ImageFormatGroup.nv21 ||
        frame.planes.length != 1) {
      throw UnsupportedError('Expected single-plane NV21 frame');
    }

    final width = frame.width;
    final height = frame.height;

    final plane = frame.planes[0];
    final bytes = plane.bytes;

    final yStride = plane.bytesPerRow;
    final uvStart = yStride * height;

    final output = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yStride + x;

        final uvIndex = uvStart + (y ~/ 2) * yStride + (x ~/ 2) * 2;

        if (yIndex >= bytes.length || uvIndex + 1 >= bytes.length) {
          throw const FormatException('Invalid NV21 frame buffer');
        }

        final yValue = bytes[yIndex];

        final v = bytes[uvIndex] - 128;
        final u = bytes[uvIndex + 1] - 128;

        final r = (yValue + 1.402 * v).clamp(0, 255).toInt();

        final g = (yValue - 0.344136 * u - 0.714136 * v).clamp(0, 255).toInt();

        final b = (yValue + 1.772 * u).clamp(0, 255).toInt();

        output.setPixelRgb(x, y, r, g, b);
      }
    }

    img.Image processedImage = output;

    if (width > height) {
      final sensorOrientation = controller?.description.sensorOrientation ?? 90;

      final rotation = sensorOrientation == 270 ? 270 : 90;

      processedImage = img.copyRotate(output, angle: rotation);
    }

    return Uint8List.fromList(img.encodeJpg(processedImage, quality: 85));
  }

  Future<void> stopDetection({String? errorMessage}) async {
    if (stopping) return;

    stopping = true;

    running = false;
    waitingForResponse = false;

    try {
      await subscription?.cancel();
      subscription = null;

      final camera = controller;

      if (camera != null && camera.value.isStreamingImages) {
        await camera.stopImageStream();
      }

      await socket?.sink.close();
      socket = null;
    } catch (e) {
      debugPrint('Stop detection error: $e');
    } finally {
      stopping = false;

      if (mounted) {
        setState(() {
          detections = [];
          imageWidth = 0;
          imageHeight = 0;

          fps = 0;
          processingMs = 0;

          status = errorMessage ?? 'Stopped';
        });
      }
    }
  }

  Widget buildCameraPreview() {
    final camera = controller;

    if (camera == null || !camera.value.isInitialized) {
      if (status.startsWith('Camera error')) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(status, textAlign: TextAlign.center),
          ),
        );
      }

      return const Center(child: CircularProgressIndicator());
    }

    return Container(
      width: double.infinity,
      height: double.infinity,
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

  @override
  Widget build(BuildContext context) {
    final cameraReady = controller?.value.isInitialized == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('YOLO Live Detection'),
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
                    'FPS: ${fps.toStringAsFixed(1)}',
                  ),

                  const SizedBox(height: 4),

                  Text(
                    'Processing: '
                    '${processingMs.toStringAsFixed(0)} ms',
                  ),

                  if (imageWidth > 0 && imageHeight > 0) ...[
                    const SizedBox(height: 4),

                    Text(
                      'Frame: '
                      '$imageWidth x $imageHeight',
                    ),
                  ],

                  const SizedBox(height: 16),

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

    subscription?.cancel();
    socket?.sink.close();

    controller?.dispose();

    super.dispose();
  }
}

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

    final fittedSizes = applyBoxFit(
      BoxFit.contain,
      Size(imageWidth.toDouble(), imageHeight.toDouble()),
      size,
    );

    final destination = fittedSizes.destination;

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

      final confidence = (item['confidence'] as num?)?.toDouble() ?? 0.0;

      final label =
          '$name '
          '${(confidence * 100).toStringAsFixed(0)}%';

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
  bool shouldRepaint(covariant LiveDetectionPainter oldDelegate) {
    return oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight ||
        oldDelegate.detections != detections;
  }
}
