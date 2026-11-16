import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/yolo_preprocessor.dart';

void main() {
  final nv21 = Uint8List.fromList([
    10, 20, 30, 40, // Y row 0
    50, 60, 70, 80, // Y row 1
    128, 128, 128, 128, // neutral VU row
  ]);

  test('NV21 input keeps NCHW layout and handles letterboxing', () {
    final input = prepareYoloInputFromNv21(
      nv21: nv21,
      width: 4,
      height: 2,
      rowStride: 4,
      rotation: 0,
    );
    expect(input.sourceWidth, 4);
    expect(input.sourceHeight, 2);
    expect(input.padLeft, 0);
    expect(input.padTop, 80);
    expect(input.bytes.length, 3 * 320 * 320 * 4);
    final tensor = Float32List.view(input.bytes.buffer);
    expect(tensor[0], closeTo(114 / 255, 0.001));
    expect(tensor[80 * 320], closeTo(10 / 255, 0.005));
  });

  test('90-degree clockwise rotation produces correct dimensions/pixels', () {
    final input = prepareYoloInputFromNv21(
      nv21: nv21,
      width: 4,
      height: 2,
      rowStride: 4,
      rotation: 90,
    );
    expect(input.sourceWidth, 2);
    expect(input.sourceHeight, 4);
    expect(input.padLeft, 80);
    expect(input.padTop, 0);
    final tensor = Float32List.view(input.bytes.buffer);
    expect(tensor[80], closeTo(50 / 255, 0.005));
  });

  test('invalid NV21 data is rejected', () {
    expect(
      () => prepareYoloInputFromNv21(
        nv21: Uint8List(3),
        width: 4,
        height: 2,
        rowStride: 4,
        rotation: 0,
      ),
      throwsFormatException,
    );
  });
  for (final rotation in [0, 90, 180, 270]) {
    test('NHWC matches NCHW and reuses buffer, rotation=$rotation', () {
      // Colored pixels and padded source rows exercise chroma/stride mapping.
      final padded = Uint8List.fromList([
        20,
        40,
        60,
        80,
        0,
        0,
        100,
        120,
        140,
        160,
        0,
        0,
        160,
        96,
        100,
        180,
        0,
        0,
      ]);
      final nchw = prepareYoloInputFromNv21(
        nv21: padded,
        width: 4,
        height: 2,
        rowStride: 6,
        rotation: rotation,
      );
      final buffer = Float32List(3 * 320 * 320)
        ..fillRange(0, 3 * 320 * 320, 42);
      final nhwc = prepareYoloInputFromNv21(
        nv21: padded,
        width: 4,
        height: 2,
        rowStride: 6,
        rotation: rotation,
        nhwc: true,
        outputBuffer: buffer,
      );
      final planar = nchw.bytes.buffer.asFloat32List();
      for (var pixel = 0; pixel < 320 * 320; pixel += 113) {
        for (var c = 0; c < 3; c++) {
          expect(buffer[pixel * 3 + c], planar[c * 320 * 320 + pixel]);
        }
      }
      expect(buffer[0], closeTo(114 / 255, 0.00001));
      buffer[0] = 0.123;
      expect(nhwc.bytes.buffer.asFloat32List()[0], buffer[0]);
    });
  }

  test('incorrect reusable buffer is rejected', () {
    expect(
      () => prepareYoloInputFromNv21(
        nv21: nv21,
        width: 4,
        height: 2,
        rowStride: 4,
        rotation: 0,
        outputBuffer: Float32List(3),
      ),
      throwsArgumentError,
    );
  });
  test('buffer reuse clears all padding after rotation and layout changes', () {
    final buffer = Float32List(3 * 320 * 320);
    for (final nhwc in [false, true, false]) {
      for (final rotation in [0, 90, 180, 270, 0]) {
        final expected = prepareYoloInputFromNv21(
          nv21: nv21,
          width: 4,
          height: 2,
          rowStride: 4,
          rotation: rotation,
          nhwc: nhwc,
        );
        final actual = prepareYoloInputFromNv21(
          nv21: nv21,
          width: 4,
          height: 2,
          rowStride: 4,
          rotation: rotation,
          nhwc: nhwc,
          outputBuffer: buffer,
        );
        expect(actual.bytes, orderedEquals(expected.bytes));
      }
    }
  });
}
