import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/yolo_postprocessor.dart';
import 'package:yolo_live_detection/services/yolo_preprocessor.dart';

void main() {
  for (final channelsFirst in [true, false]) {
    test(
      'Float32 output preserves boxes and NMS (channelsFirst=$channelsFirst)',
      () {
        final values = Float32List(29 * 2100);
        void put(int candidate, int channel, double value) {
          values[channelsFirst
                  ? channel * 2100 + candidate
                  : candidate * 29 + channel] =
              value;
        }

        // Two overlapping persons: only the higher confidence box survives.
        for (var i = 0; i < 2; i++) {
          put(i, 0, 0.5);
          put(i, 1, 0.5);
          put(i, 2, 0.25);
          put(i, 3, 0.25);
          put(i, 7, i == 0 ? 0.9 : 0.8);
        }
        final geometry = PreparedYoloInput(
          bytes: Uint8List(0),
          sourceWidth: 640,
          sourceHeight: 320,
          scale: 0.5,
          padLeft: 0,
          padTop: 80,
        );
        // Match the service's native byte-buffer view, including a byte offset.
        final backing = Uint8List(values.lengthInBytes + 4);
        backing.setRange(4, backing.length, values.buffer.asUint8List());
        final output = backing.buffer.asFloat32List(4, values.length);
        final result = YoloPostprocessor.decodeFromFloat32(
          output,
          channelsFirst ? [1, 29, 2100] : [1, 2100, 29],
          geometry,
        );
        expect(result, hasLength(1));
        expect(result.single['class_name'], 'Person');
        expect(result.single['confidence'], closeTo(0.9, 0.00001));
        expect(result.single['bbox'], [240.0, 80.0, 400.0, 240.0]);
      },
    );
  }
}
