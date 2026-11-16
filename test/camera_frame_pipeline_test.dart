import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:camera_android_camerax/src/analysis_frame_processor.dart';
import 'package:camera_android_camerax/src/camerax_library.g.dart';

class FakeImage extends ImageProxy {
  FakeImage() : super.pigeon_detached(format: 35, width: 4, height: 2);
  final counts = <int>[0, 0];
  int get closed => counts[0];
  int get planesRead => counts[1];
  @override
  Future<List<PlaneProxy>> getPlanes() async {
    counts[1]++;
    throw StateError('NV21 must not serialize three plane buffers');
  }

  @override
  Future<void> close() async {
    counts[0]++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PigeonOverrides.pigeon_reset);
  test('busy worker drops image before copying bytes and closes it', () async {
    final image = FakeImage();
    var conversions = 0;
    PigeonOverrides.imageProxyUtils_getNv21Buffer = (_) async {
      conversions++;
      return Uint8List(12);
    };
    await processAnalysisFrame(
      image: image,
      nv21: true,
      admit: () => false,
      deliver: (_) => fail('dropped frame delivered'),
    );
    expect(conversions, 0);
    expect(image.planesRead, 0);
    expect(image.closed, 1);
  });
  test('NV21 directly transfers packed bytes, geometry unchanged', () async {
    final image = FakeImage();
    final bytes = Uint8List.fromList(List.generate(12, (i) => i));
    PigeonOverrides.imageProxyUtils_getNv21Buffer = (source) async {
      expect(source, same(image));
      return bytes;
    };
    var delivered = false;
    await processAnalysisFrame(
      image: image,
      nv21: true,
      deliver: (data) {
        delivered = true;
        expect(data.width, 4);
        expect(data.height, 2);
        expect(data.planes.single.bytes, same(bytes));
        expect(data.planes.single.bytesPerRow, 4);
        expect(data.format.raw, 17);
      },
    );
    expect(delivered, isTrue);
    expect(image.planesRead, 0);
    expect(image.closed, 1);
  });
  test('conversion failure still closes the image', () async {
    final image = FakeImage();
    PigeonOverrides.imageProxyUtils_getNv21Buffer = (_) async =>
        throw StateError('native failure');
    await expectLater(
      processAnalysisFrame(
        image: image,
        nv21: true,
        deliver: (_) => fail('failure delivered'),
      ),
      throwsStateError,
    );
    expect(image.closed, 1);
  });
  test('disposal or admission failure cannot leak camera images', () async {
    final image = FakeImage();
    await expectLater(
      processAnalysisFrame(
        image: image,
        nv21: true,
        admit: () => throw StateError('disposed'),
        deliver: (_) {},
      ),
      throwsStateError,
    );
    expect(image.closed, 1);
  });
}
