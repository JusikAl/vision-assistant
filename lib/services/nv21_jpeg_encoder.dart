import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Runs in the existing encoder isolate; rear-camera images are never mirrored.
Uint8List encodeNv21Jpeg(
  Uint8List data,
  int width,
  int height,
  int stride,
  int rotation, {
  int maxDimension = 960,
}) {
  if (width <= 0 ||
      height <= 0 ||
      width.isOdd ||
      height.isOdd ||
      stride < width ||
      stride.isOdd ||
      maxDimension <= 0 ||
      !const [0, 90, 180, 270].contains(rotation) ||
      data.length < stride * height + stride * (height ~/ 2)) {
    throw const FormatException('Invalid NV21 geometry');
  }
  final longest = width > height ? width : height;
  final scale = longest > maxDimension ? maxDimension / longest : 1.0;
  final targetWidth = (width * scale).round().clamp(1, maxDimension);
  final targetHeight = (height * scale).round().clamp(1, maxDimension);
  final image = img.Image(width: targetWidth, height: targetHeight);
  final uvStart = stride * height;
  for (var y = 0; y < targetHeight; y++) {
    final sy = y * height ~/ targetHeight;
    for (var x = 0; x < targetWidth; x++) {
      final sx = x * width ~/ targetWidth;
      final uv = uvStart + (sy ~/ 2) * stride + (sx ~/ 2) * 2;
      final luma = data[sy * stride + sx];
      final v = data[uv] - 128, u = data[uv + 1] - 128;
      image.setPixelRgb(
        x,
        y,
        (luma + 1.402 * v).clamp(0, 255).toInt(),
        (luma - .344136 * u - .714136 * v).clamp(0, 255).toInt(),
        (luma + 1.772 * u).clamp(0, 255).toInt(),
      );
    }
  }
  final oriented = rotation == 0
      ? image
      : img.copyRotate(image, angle: rotation);
  return Uint8List.fromList(img.encodeJpg(oriented, quality: 78));
}
