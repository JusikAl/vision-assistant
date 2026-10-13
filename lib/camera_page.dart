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
  final picker = ImagePicker();

  bool isLoading = false;
  String? errorMessage;
  List<dynamic> detections = [];

  static const String apiUrl = 'http://192.168.8.28:8000/detect';

  Future<void> pickImage(ImageSource source) async {
    final pickedFile = await picker.pickImage(source: source);

    if (pickedFile != null) {
      setState(() {
        image = File(pickedFile.path);
        detections = [];
        errorMessage = null;
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
                child: image != null
                    ? Image.file(image!, fit: BoxFit.contain)
                    : const Center(child: Text('No image selected')),
              ),

              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                    onPressed: isLoading
                        ? null
                        : () => pickImage(ImageSource.camera),
                    child: const Text('Camera'),
                  ),
                  ElevatedButton(
                    onPressed: isLoading
                        ? null
                        : () => pickImage(ImageSource.gallery),
                    child: const Text('Gallery'),
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
                      leading: const Icon(Icons.visibility),
                      title: Text('$name'),
                      subtitle: Text(
                        'Confidence: ${(confidence * 100).toStringAsFixed(1)}%\n'
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
                const Text('No objects detected.'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
