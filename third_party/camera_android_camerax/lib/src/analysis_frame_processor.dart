// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'camerax_library.dart';

/// Admission precedes plane serialization. A proxy is closed on every path,
/// including rejected frames, native conversion errors and stream disposal.
Future<void> processAnalysisFrame({
  required ImageProxy image,
  required bool nv21,
  required void Function(CameraImageData) deliver,
  bool Function()? admit,
  void Function(Map<String, num>)? profile,
}) async {
  try {
    if (admit?.call() == false) return;
    final watch = profile == null ? null : (Stopwatch()..start());
    final planes = <CameraImagePlane>[];
    if (nv21) {
      final bytes = await ImageProxyUtils.getNv21Buffer(image);
      planes.add(
        CameraImagePlane(
          bytes: bytes,
          bytesPerRow: image.width,
          bytesPerPixel: 1,
        ),
      );
    } else {
      for (final plane in await image.getPlanes()) {
        planes.add(
          CameraImagePlane(
            bytes: plane.buffer,
            bytesPerRow: plane.rowStride,
            bytesPerPixel: plane.pixelStride,
          ),
        );
      }
    }
    profile?.call({
      'camera_conversion_channel_ms': watch!.elapsedMicroseconds / 1000,
      'camera_bytes': planes.fold<int>(
        0,
        (sum, plane) => sum + plane.bytes.length,
      ),
      'camera_width': image.width,
      'camera_height': image.height,
    });
    final group = nv21
        ? ImageFormatGroup.nv21
        : switch (image.format) {
            35 => ImageFormatGroup.yuv420,
            256 => ImageFormatGroup.jpeg,
            17 => ImageFormatGroup.nv21,
            _ => ImageFormatGroup.unknown,
          };
    deliver(
      CameraImageData(
        format: CameraImageFormat(group, raw: nv21 ? 17 : image.format),
        planes: planes,
        width: image.width,
        height: image.height,
      ),
    );
  } finally {
    await image.close();
  }
}
