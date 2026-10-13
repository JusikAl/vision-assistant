import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  File? image;
  int? imageWidth;
  int? imageHeight;

  final picker = ImagePicker();

  bool isLoading = false;
  String? errorMessage;
  List<dynamic> detections = [];

  static const String apiUrl = 'http://192.168.10.4:8000/detect';

  Future<void> pickImage(ImageSource source) async {
    try {
      final pickedFile = await picker.pickImage(source: source);

      if (pickedFile == null) return;

      final bytes = await File(pickedFile.path).readAsBytes();
      final decoded = await decodeImageFromList(bytes);

      final width = decoded.width;
      final height = decoded.height;
      decoded.dispose();

      if (!mounted) return;

      setState(() {
        image = File(pickedFile.path);
        imageWidth = width;
        imageHeight = height;
        detections = [];
        errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        errorMessage = 'Could not load image: $e';
      });
    }
  }

  Future<void> detectObjects() async {
    if (image == null || isLoading) return;

    setState(() {
      isLoading = true;
      errorMessage = null;
      detections = [];
    });

    try {
      final request = http.MultipartRequest('POST', Uri.parse(apiUrl));

      request.files.add(await http.MultipartFile.fromPath('file', image!.path));

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );

      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200) {
        throw Exception(
          'Server error ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final result = data['detections'] as List<dynamic>;

      if (!mounted) return;

      setState(() {
        detections = result;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        errorMessage = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('YOLO Object Detection')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 300,
                width: double.infinity,
                child: image != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(image!, fit: BoxFit.contain),
                          if (detections.isNotEmpty &&
                              imageWidth != null &&
                              imageHeight != null)
                            CustomPaint(
                              painter: DetectionPainter(
                                imageWidth: imageWidth!,
                                imageHeight: imageHeight!,
                                detections: detections,
                              ),
                            ),
                        ],
                      )
                    : const Center(child: Text('No image selected')),
              ),

              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () => pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                  ),
                  ElevatedButton.icon(
                    onPressed: isLoading
                        ? null
                        : () => pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              ElevatedButton.icon(
                onPressed: image == null || isLoading ? null : detectObjects,
                icon: const Icon(Icons.search),
                label: Text(isLoading ? 'Detecting...' : 'Detect Objects'),
              ),

              if (isLoading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                const Text(
                  'YOLO is processing the image...',
                  textAlign: TextAlign.center,
                ),
              ],

              if (errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Error: $errorMessage',
                  style: const TextStyle(color: Colors.red),
                ),
              ],

              if (!isLoading &&
                  errorMessage == null &&
                  detections.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Detected objects: ${detections.length}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),

                ...detections.map((item) {
                  final detection = item as Map<String, dynamic>;
                  final name = detection['class_name'];
                  final confidence = (detection['confidence'] as num)
                      .toDouble();
                  final bbox = detection['bbox'] as List<dynamic>;

                  return Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.visibility,
                        color: Colors.green,
                      ),
                      title: Text('$name'),
                      subtitle: Text(
                        'Confidence: '
                        '${(confidence * 100).toStringAsFixed(1)}%\n'
                        'BBox: ${bbox.map((v) => (v as num).toStringAsFixed(1)).join(', ')}',
                      ),
                      isThreeLine: true,
                    ),
                  );
                }),
              ],

              if (!isLoading &&
                  errorMessage == null &&
                  image != null &&
                  detections.isEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  'No objects detected yet. '
                  'Press Detect Objects to start.',
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DetectionPainter extends CustomPainter {
  final int imageWidth;
  final int imageHeight;
  final List<dynamic> detections;

  DetectionPainter({
    required this.imageWidth,
    required this.imageHeight,
    required this.detections,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Match the BoxFit.contain scale used by Image.file.
    final scaleX = size.width / imageWidth;
    final scaleY = size.height / imageHeight;
    final actualScale = scaleX < scaleY ? scaleX : scaleY;

    // Center the scaled image inside the display area.
    final offsetX = (size.width - imageWidth * actualScale) / 2;
    final offsetY = (size.height - imageHeight * actualScale) / 2;

    final boxPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final labelPaint = Paint()
      ..color = Colors.green.shade800
      ..style = PaintingStyle.fill;

    for (final item in detections) {
      final detection = item as Map<String, dynamic>;
      final bbox = detection['bbox'] as List<dynamic>;

      if (bbox.length < 4) continue;

      final x1 = (bbox[0] as num).toDouble() * actualScale + offsetX;
      final y1 = (bbox[1] as num).toDouble() * actualScale + offsetY;
      final x2 = (bbox[2] as num).toDouble() * actualScale + offsetX;
      final y2 = (bbox[3] as num).toDouble() * actualScale + offsetY;

      final rect = Rect.fromLTRB(x1, y1, x2, y2);

      canvas.drawRect(rect, boxPaint);

      final name = detection['class_name']?.toString() ?? 'Object';
      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;

      final textPainter = TextPainter(
        text: TextSpan(
          text: '$name ${(confidence * 100).toStringAsFixed(0)}%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);

      final labelTop = (y1 - textPainter.height - 8)
          .clamp(0.0, size.height)
          .toDouble();

      final labelLeft = x1.clamp(0.0, size.width).toDouble();

      final labelRect = Rect.fromLTWH(
        labelLeft,
        labelTop,
        (textPainter.width + 10).clamp(0.0, size.width - labelLeft).toDouble(),
        (textPainter.height + 6).clamp(0.0, size.height - labelTop).toDouble(),
      );

      canvas.drawRect(labelRect, labelPaint);

      textPainter.paint(canvas, Offset(labelRect.left + 5, labelRect.top + 3));
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter oldDelegate) {
    return oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight ||
        oldDelegate.detections != detections;
  }
}
