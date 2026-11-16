// Synthetic diagnostics only. No camera capture or network. Run in profile.
// flutter run --profile -d <device> -t tool/offline_safety_smoke.dart
import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:yolo_live_detection/safety_tts_service.dart';
import 'package:yolo_live_detection/services/local_yolo_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            'ТЕСТ: синтетические детекции и русский офлайн-голос.\nНе навигационные указания.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    ),
  );
  unawaited(_run());
}

Future<void> _run() async {
  final yolo = LocalYoloService();
  final speaker = SafetyTtsService();
  final bytes = Uint8List(640 * 480 * 3 ~/ 2)..fillRange(0, 640 * 480, 114);
  bytes.fillRange(640 * 480, bytes.length, 128);
  // Synthetic platform message avoids a dependency only for diagnostics.
  // ignore: deprecated_member_use
  final frame = CameraImage.fromPlatformData({
    'format': 17,
    'width': 640,
    'height': 480,
    'planes': [
      {'bytes': bytes, 'bytesPerRow': 640},
    ],
  });
  try {
    await yolo.initialize();
    await speaker.initialize();
    for (final speech in [false, true]) {
      final durations = <double>[];
      final safetyTimes = <double>[];
      final total = Stopwatch()..start();
      yolo.beginSession();
      for (var i = 0; i < 60; i++) {
        final result = await yolo.detectNv21(frame, 90);
        durations.add(result.yoloMs);
        if (speech) {
          if (i == 0) {
            unawaited(
              speaker.speakMessage(
                'Проверка голосовых предупреждений. '
                'Это тестовое описание сцены, которое должно быть прервано '
                'подтверждённым предупреждением с более высоким приоритетом.',
              ),
            );
          }
          final objects = <Map<String, dynamic>>[
            for (var j = 0; j < 40; j++)
              {
                'class_name': i < 12 ? 'Car' : 'Stairs',
                'confidence': .95,
                'bbox': [200.0, 100.0, 400.0, 400.0],
              },
          ];
          speaker.onDetections(
            detections: objects,
            imageWidth: 480,
            imageHeight: 640,
            frameAgeMs: result.processingMs,
          );
          safetyTimes.add(speaker.lastSafetyMs);
        }
      }
      durations.sort();
      safetyTimes.sort();
      debugPrint(
        'SAFETY SMOKE synthetic=true speech=$speech frames=60 '
        'median_inference_ms=${durations[30]} '
        'delivered_fps=${60000 / total.elapsedMilliseconds} '
        'median_safety_ms=${safetyTimes.isEmpty ? 0 : safetyTimes[30]} '
        'max_safety_ms=${safetyTimes.isEmpty ? 0 : safetyTimes.last}',
      );
      await speaker.stop();
    }
    debugPrint(
      'SAFETY SMOKE COMPLETE offline_voice=${speaker.offlineVoiceReady}',
    );
  } catch (error, stack) {
    debugPrint('SAFETY SMOKE ERROR $error\n$stack');
  } finally {
    await speaker.dispose();
    await yolo.dispose();
  }
}
