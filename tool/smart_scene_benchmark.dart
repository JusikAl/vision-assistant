// Reproducible CPU-only stress measurement; not camera FPS or acoustic latency.
import 'dart:convert';
import 'dart:io';

import 'package:yolo_live_detection/services/safety_service.dart';

void main() {
  var now = DateTime(2026);
  final service = SafetyService(clock: () => now);
  final objects = List.generate(80, (i) {
    final x = (i % 10) * 10;
    final y = (i ~/ 10) * 12;
    return {
      'class_name': i < 50
          ? 'person'
          : i < 70
          ? 'car'
          : 'stairs',
      'confidence': .9,
      'bbox': [x, y, x + 6, y + 10],
    };
  });
  final samples = <int>[];
  var groups = 0;
  for (var i = 0; i < 11000; i++) {
    now = now.add(const Duration(milliseconds: 307));
    final watch = Stopwatch()..start();
    groups = service
        .evaluate(detections: objects, imageWidth: 100, imageHeight: 100)
        .length;
    if (i >= 1000) samples.add(watch.elapsedMicroseconds);
  }
  samples.sort();
  stdout.writeln(
    jsonEncode({
      'scope':
          'host Dart JIT, SafetyService plus SmartSceneAnalyzer, 80 detections',
      'warmup': 1000,
      'samples': samples.length,
      'output_groups': groups,
      'p50_ms': samples[samples.length ~/ 2] / 1000,
      'p95_ms': samples[((samples.length - 1) * .95).ceil()] / 1000,
      'max_ms': samples.last / 1000,
    }),
  );
}
