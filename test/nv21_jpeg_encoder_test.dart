import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:yolo_live_detection/services/nv21_jpeg_encoder.dart';

void main() {
  Uint8List quadrants({int stride = 72}) {
    final data = Uint8List(stride * 32 * 3 ~/ 2)
      ..fillRange(0, stride * 32 * 3 ~/ 2, 128);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 64; x++) {
        data[y * stride + x] = [
          32,
          96,
          160,
          224,
        ][(y < 16 ? 0 : 2) + (x < 32 ? 0 : 1)];
      }
    }
    return data;
  }

  test(
    'portrait rear-camera rotation preserves left/right without reflection',
    () {
      final image = img.decodeJpg(encodeNv21Jpeg(quadrants(), 64, 32, 72, 90))!;
      expect((image.width, image.height), (32, 64));
      expect(image.getPixel(8, 16).r, closeTo(160, 5));
      expect(image.getPixel(24, 16).r, closeTo(32, 5));
      expect(image.getPixel(8, 48).r, closeTo(224, 5));
      expect(image.getPixel(24, 48).r, closeTo(96, 5));
    },
  );
  test('requested JPEG preserves aspect and max dimension', () {
    final image = img.decodeJpg(
      encodeNv21Jpeg(quadrants(), 64, 32, 72, 270, maxDimension: 32),
    )!;
    expect((image.width, image.height), (16, 32));
  });
  test('invalid stride or truncated camera plane fails safely', () {
    expect(
      () => encodeNv21Jpeg(Uint8List(4), 64, 32, 64, 90),
      throwsFormatException,
    );
    expect(
      () => encodeNv21Jpeg(quadrants(), 64, 32, 60, 90),
      throwsFormatException,
    );
  });
}
