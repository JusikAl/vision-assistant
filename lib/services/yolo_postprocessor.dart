import 'dart:math' as math;
import 'dart:typed_data';

import 'yolo_preprocessor.dart';

class _Candidate {
  const _Candidate(
    this.classId,
    this.score,
    this.x1,
    this.y1,
    this.x2,
    this.y2,
  );

  final int classId;
  final double score;
  final double x1;
  final double y1;
  final double x2;
  final double y2;
}

class YoloPostprocessor {
  static const int inputSize = 320;
  static const int candidatesCount = 2100;
  static const int classCount = 25;
  static const int channels = 4 + classCount;
  static const double confidenceThreshold = 0.25;
  static const double iouThreshold = 0.45;
  static const int maxDetections = 40;

  static const List<String> classNames = [
    'Bike',
    'Building',
    'Car',
    'Person',
    'Stairs',
    'Traffic sign',
    'Electrical Pole',
    'Road',
    'Motorcycle',
    'Dustbin',
    'Dog',
    'Manhole',
    'Tree',
    'Guard rail',
    'Pedestrian crosswalk',
    'Truck',
    'Bus',
    'Bench',
    'Traffic Cone',
    'Fire hydrant',
    'Teraffic Barrel',
    'Plant Pot',
    'Electrical Box',
    'Chair',
    'Bicycle Rack',
  ];

  // Compatibility with older call sites (channels-first Float32 buffer).
  static List<Map<String, dynamic>> decode(
    Uint8List outputBytes,
    PreparedYoloInput geometry,
  ) {
    const count = channels * candidatesCount;
    if (outputBytes.lengthInBytes != count * Float32List.bytesPerElement) {
      throw StateError(
        'Unexpected YOLO output byte count: ${outputBytes.lengthInBytes}',
      );
    }
    final values = Float32List.view(
      outputBytes.buffer,
      outputBytes.offsetInBytes,
      count,
    );
    return decodeFromFloat32(values, const [
      1,
      channels,
      candidatesCount,
    ], geometry);
  }

  static List<Map<String, dynamic>> decodeFromFloat32(
    Float32List tensor,
    List<int> shape,
    PreparedYoloInput geometry,
  ) {
    final channelsFirst =
        shape.length == 3 &&
        shape[0] == 1 &&
        shape[1] == channels &&
        shape[2] == candidatesCount;
    final candidatesFirst =
        shape.length == 3 &&
        shape[0] == 1 &&
        shape[1] == candidatesCount &&
        shape[2] == channels;
    if (!channelsFirst && !candidatesFirst) {
      throw StateError('Unsupported YOLO output shape: $shape');
    }
    if (tensor.length != channels * candidatesCount) {
      throw StateError('Unexpected YOLO output length: ${tensor.length}');
    }

    double value(int channel, int index) => channelsFirst
        ? tensor[channel * candidatesCount + index]
        : tensor[index * channels + channel];

    // Ultralytics exports may return boxes either as normalized [0..1]
    // coordinates or already in 320x320 input pixels. Detect the layout
    // once per output, instead of multiplying every box blindly by 320.
    var largestCoordinate = 0.0;
    for (var i = 0; i < candidatesCount; i += 7) {
      for (var c = 0; c < 4; c++) {
        final coordinate = value(c, i);
        if (coordinate.isFinite) {
          largestCoordinate = math.max(largestCoordinate, coordinate.abs());
        }
      }
    }
    final multiplier = largestCoordinate <= 2.0 ? inputSize.toDouble() : 1.0;

    final candidates = <_Candidate>[];
    for (var i = 0; i < candidatesCount; i++) {
      var bestClass = -1;
      var bestScore = confidenceThreshold;
      for (var c = 0; c < classCount; c++) {
        final score = value(c + 4, i);
        if (score.isFinite && score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      if (bestClass < 0) continue;

      final cx = value(0, i) * multiplier;
      final cy = value(1, i) * multiplier;
      final w = value(2, i) * multiplier;
      final h = value(3, i) * multiplier;
      if (!cx.isFinite ||
          !cy.isFinite ||
          !w.isFinite ||
          !h.isFinite ||
          w <= 0 ||
          h <= 0) {
        continue;
      }

      final x1 = ((cx - w / 2 - geometry.padLeft) / geometry.scale)
          .clamp(0.0, geometry.sourceWidth.toDouble())
          .toDouble();
      final y1 = ((cy - h / 2 - geometry.padTop) / geometry.scale)
          .clamp(0.0, geometry.sourceHeight.toDouble())
          .toDouble();
      final x2 = ((cx + w / 2 - geometry.padLeft) / geometry.scale)
          .clamp(0.0, geometry.sourceWidth.toDouble())
          .toDouble();
      final y2 = ((cy + h / 2 - geometry.padTop) / geometry.scale)
          .clamp(0.0, geometry.sourceHeight.toDouble())
          .toDouble();
      if (x2 - x1 < 1 || y2 - y1 < 1) continue;
      candidates.add(_Candidate(bestClass, bestScore, x1, y1, x2, y2));
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    final selected = <_Candidate>[];
    for (final candidate in candidates) {
      if (selected.length >= maxDetections) break;
      if (selected.any(
        (previous) =>
            previous.classId == candidate.classId &&
            _iou(previous, candidate) > iouThreshold,
      )) {
        continue;
      }
      selected.add(candidate);
    }

    return selected
        .map(
          (item) => <String, dynamic>{
            'class_name': classNames[item.classId],
            'confidence': item.score,
            'bbox': [item.x1, item.y1, item.x2, item.y2],
          },
        )
        .toList(growable: false);
  }

  static double _iou(_Candidate a, _Candidate b) {
    final width = math.max(0.0, math.min(a.x2, b.x2) - math.max(a.x1, b.x1));
    final height = math.max(0.0, math.min(a.y2, b.y2) - math.max(a.y1, b.y1));
    final intersection = width * height;
    final areaA = (a.x2 - a.x1) * (a.y2 - a.y1);
    final areaB = (b.x2 - b.x1) * (b.y2 - b.y1);
    final union = areaA + areaB - intersection;
    return union > 0 ? intersection / union : 0.0;
  }
}
