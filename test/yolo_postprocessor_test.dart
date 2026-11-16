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

  test('NV21 input in NHWC layout is interleaved', () {
    final input = prepareYoloInputFromNv21(
      nv21: nv21,
      width: 4,
      height: 2,
      rowStride: 4,
      rotation: 0,
      nhwc: true,
    );
    expect(input.bytes.length, 3 * 320 * 320 * 4);
    final tensor = Float32List.view(input.bytes.buffer);
    // padding
    expect(tensor[0], closeTo(114 / 255, 0.001));
    // first real pixel (y = 80, x = 0): R, G, B all ≈ luma 10 (neutral chroma)
    final o = (80 * 320 + 0) * 3;
    expect(tensor[o], closeTo(10 / 255, 0.005));
    expect(tensor[o + 1], closeTo(10 / 255, 0.005));
    expect(tensor[o + 2], closeTo(10 / 255, 0.005));
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
}
