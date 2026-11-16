import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class PreparedYoloInput {
  const PreparedYoloInput({
    required this.bytes,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.scale,
    required this.padLeft,
    required this.padTop,
  });

  final Uint8List bytes;
  final int sourceWidth;
  final int sourceHeight;
  final double scale;
  final int padLeft;
  final int padTop;
}

/// JPEG path retained for compatibility (not used offline). Always NCHW.
PreparedYoloInput prepareYoloInput(Uint8List jpegBytes) {
  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) {
    throw const FormatException('Cannot decode camera JPEG');
  }

  const side = 320;
  final width = decoded.width;
  final height = decoded.height;
  if (width <= 0 || height <= 0) {
    throw const FormatException('Invalid JPEG dimensions');
  }

  final scale = math.min(side / width, side / height);
  final scaledWidth = (width * scale).round().clamp(1, side).toInt();
  final scaledHeight = (height * scale).round().clamp(1, side).toInt();
  final padLeft = (side - scaledWidth) ~/ 2;
  final padTop = (side - scaledHeight) ~/ 2;

  final resized = img.copyResize(
    decoded,
    width: scaledWidth,
    height: scaledHeight,
    interpolation: img.Interpolation.linear,
  );

  final values = Float32List(3 * side * side);
  values.fillRange(0, values.length, 114.0 / 255.0);

  const channelLength = side * side;

  for (var y = 0; y < scaledHeight; y++) {
    for (var x = 0; x < scaledWidth; x++) {
      final pixel = resized.getPixel(x, y);
      final index = (y + padTop) * side + x + padLeft;
      values[index] = pixel.r.toDouble() / 255.0;
      values[channelLength + index] = pixel.g.toDouble() / 255.0;
      values[channelLength * 2 + index] = pixel.b.toDouble() / 255.0;
    }
  }

  return PreparedYoloInput(
    bytes: values.buffer.asUint8List(
      values.offsetInBytes,
      values.lengthInBytes,
    ),
    sourceWidth: width,
    sourceHeight: height,
    scale: scale,
    padLeft: padLeft,
    padTop: padTop,
  );
}

/// Fast NV21 -> float32. Integer YUV->RGB, integer sampling.
///
/// [nhwc] = false -> planar NCHW  [1, 3, 320, 320]
/// [nhwc] = true  -> interleaved NHWC [1, 320, 320, 3]
/// (большинство TFLite-экспортов Ultralytics / onnx2tf — NHWC).
PreparedYoloInput prepareYoloInputFromNv21({
  required Uint8List nv21,
  required int width,
  required int height,
  required int rowStride,
  required int rotation,
  bool nhwc = false,
  Float32List? outputBuffer,
}) {
  if (width <= 0 || height <= 0 || rowStride < width) {
    throw const FormatException('Invalid NV21 dimensions or stride');
  }
  if (rotation != 0 && rotation != 90 && rotation != 180 && rotation != 270) {
    throw ArgumentError.value(rotation, 'rotation', 'Expected 0/90/180/270');
  }

  final uvRowBytes = ((width + 1) ~/ 2) * 2;
  if (uvRowBytes > rowStride) {
    throw const FormatException('NV21 stride too short for chroma');
  }

  final uvStart = rowStride * height;
  final chromaRows = (height + 1) ~/ 2;
  final requiredLength = uvStart + rowStride * (chromaRows - 1) + uvRowBytes;
  if (nv21.length < requiredLength) {
    throw FormatException(
      'NV21 buffer too small (${nv21.length} < $requiredLength)',
    );
  }

  const side = 320;
  const planeSize = side * side;
  const inv255 = 1.0 / 255.0;

  final swapAxes = rotation == 90 || rotation == 270;
  final orientedWidth = swapAxes ? height : width;
  final orientedHeight = swapAxes ? width : height;

  final scale = math.min(side / orientedWidth, side / orientedHeight);
  final scaledWidth = (orientedWidth * scale).round().clamp(1, side).toInt();
  final scaledHeight = (orientedHeight * scale).round().clamp(1, side).toInt();
  final padLeft = (side - scaledWidth) ~/ 2;
  final padTop = (side - scaledHeight) ~/ 2;

  if (outputBuffer != null && outputBuffer.length != 3 * planeSize) {
    throw ArgumentError('Expected a 3x320x320 Float32 output buffer');
  }
  final values = outputBuffer ?? Float32List(3 * planeSize);
  // Only letterbox pixels need clearing; image pixels are overwritten.
  final channels = nhwc ? 1 : 3;
  final pixelStride = nhwc ? 3 : 1;
  for (var channel = 0; channel < channels; channel++) {
    final base = channel * planeSize;
    values.fillRange(base, base + padTop * side * pixelStride, 114.0 * inv255);
    values.fillRange(
      base + (padTop + scaledHeight) * side * pixelStride,
      base + planeSize * pixelStride,
      114.0 * inv255,
    );
    if (padLeft > 0 || padLeft + scaledWidth < side) {
      for (var y = padTop; y < padTop + scaledHeight; y++) {
        final row = base + y * side * pixelStride;
        values.fillRange(row, row + padLeft * pixelStride, 114.0 * inv255);
        values.fillRange(
          row + (padLeft + scaledWidth) * pixelStride,
          row + side * pixelStride,
          114.0 * inv255,
        );
      }
    }
  }

  final xMap = Int32List(scaledWidth);
  for (var x = 0; x < scaledWidth; x++) {
    final mapped = ((2 * x + 1) * orientedWidth) ~/ (2 * scaledWidth);
    xMap[x] = mapped < orientedWidth ? mapped : orientedWidth - 1;
  }

  for (var y = 0; y < scaledHeight; y++) {
    final mappedY = ((2 * y + 1) * orientedHeight) ~/ (2 * scaledHeight);
    final orientedY = mappedY < orientedHeight ? mappedY : orientedHeight - 1;

    final destRow = (y + padTop) * side + padLeft;

    for (var x = 0; x < scaledWidth; x++) {
      final orientedX = xMap[x];

      final int sx;
      final int sy;
      switch (rotation) {
        case 90:
          sx = orientedY;
          sy = height - 1 - orientedX;
          break;
        case 180:
          sx = width - 1 - orientedX;
          sy = height - 1 - orientedY;
          break;
        case 270:
          sx = width - 1 - orientedY;
          sy = orientedX;
          break;
        default:
          sx = orientedX;
          sy = orientedY;
          break;
      }

      final luma = nv21[sy * rowStride + sx];
      final uvIndex = uvStart + (sy >> 1) * rowStride + (sx & ~1);
      final v = nv21[uvIndex] - 128;
      final u = nv21[uvIndex + 1] - 128;

      // Integer YUV->RGB (BT.601), scaled by 256.
      final r = luma + ((359 * v) >> 8);
      final g = luma - ((88 * u) >> 8) - ((183 * v) >> 8);
      final b = luma + ((454 * u) >> 8);

      final rf = r <= 0 ? 0.0 : (r >= 255 ? 1.0 : r * inv255);
      final gf = g <= 0 ? 0.0 : (g >= 255 ? 1.0 : g * inv255);
      final bf = b <= 0 ? 0.0 : (b >= 255 ? 1.0 : b * inv255);

      final pixelIndex = destRow + x;

      if (nhwc) {
        final o = pixelIndex * 3;
        values[o] = rf;
        values[o + 1] = gf;
        values[o + 2] = bf;
      } else {
        values[pixelIndex] = rf;
        values[planeSize + pixelIndex] = gf;
        values[2 * planeSize + pixelIndex] = bf;
      }
    }
  }

  return PreparedYoloInput(
    bytes: values.buffer.asUint8List(
      values.offsetInBytes,
      values.lengthInBytes,
    ),
    sourceWidth: orientedWidth,
    sourceHeight: orientedHeight,
    scale: scale,
    padLeft: padLeft,
    padTop: padTop,
  );
}
