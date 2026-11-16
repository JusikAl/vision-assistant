import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/local_yolo_service.dart';

// Exercise the real service/ports/backpressure without native TFLite on host.
void fakeWorker(dynamic init) {
  final commands = ReceivePort();
  final reply = init.replyPort as SendPort;
  reply.send({
    'type': 'ready',
    'port': commands.sendPort,
    'interpreterInitMs': 1,
    'warmupMs': 2,
  });
  commands.listen((dynamic message) {
    if (message == 'dispose') {
      reply.send({'type': 'disposed'});
      commands.close();
      return;
    }
    Timer(const Duration(milliseconds: 80), () {
      reply.send({
        'type': 'result',
        'id': message.id,
        'ok': true,
        'detections': <Map<String, dynamic>>[],
        'imageWidth': 4,
        'imageHeight': 2,
        'processingMs': 80,
        'yoloMs': 70,
        'preprocessMs': 8,
        'postprocessMs': 1,
        'inputCopyMs': 1,
        'firstFrame': false,
      });
    });
  });
}

void exitingWorker(dynamic init) {}

void failingWorker(dynamic init) {
  (init.replyPort as SendPort).send({
    'type': 'init_error',
    'error': 'invalid tensor shape',
    'stack': '',
  });
}

void crashingFrameWorker(dynamic init) {
  final port = ReceivePort();
  (init.replyPort as SendPort).send({
    'type': 'ready',
    'port': port.sendPort,
    'interpreterInitMs': 1,
    'warmupMs': 1,
  });
  port.listen((dynamic _) => throw StateError('simulated worker crash'));
}

CameraImage fakeFrame() {
  // Synthetic platform message, no camera/plugin dependency in host tests.
  // ignore: deprecated_member_use
  return CameraImage.fromPlatformData({
    'format': 17,
    'width': 4,
    'height': 2,
    'planes': [
      {'bytes': Uint8List(12), 'bytesPerRow': 4},
    ],
  });
}

Future<void> waitForDrain(LocalYoloService service) async {
  final deadline = Stopwatch()..start();
  while (service.isBusy) {
    if (deadline.elapsedMilliseconds > 2000) fail('Worker did not drain');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'concurrent initialization and repeated Start reuse one worker',
    () async {
      var loads = 0;
      final service = LocalYoloService(
        modelLoader: () async {
          loads++;
          return ByteData(1);
        },
        workerEntryPoint: fakeWorker,
      );
      addTearDown(service.dispose);
      await Future.wait([service.initialize(), service.initialize()]);
      expect(service.isReady, isTrue);
      await service.initialize();
      expect(loads, 1);
      service.beginSession();
      final result = await service.detectNv21(fakeFrame(), 0);
      expect(result.imageWidth, 4);
      await service.initialize();
      expect(loads, 1);
    },
  );

  test('Stop cancels result but retains native slot until reply', () async {
    final service = LocalYoloService(
      modelLoader: () async => ByteData(1),
      workerEntryPoint: fakeWorker,
    );
    addTearDown(service.dispose);
    await service.initialize();
    final future = service.detectNv21(fakeFrame(), 0);
    final cancelled = expectLater(future, throwsA(isA<YoloRequestCancelled>()));
    service.cancelPending();
    await cancelled;
    expect(service.isBusy, isTrue);
    await expectLater(service.detectNv21(fakeFrame(), 0), throwsStateError);
    await waitForDrain(service);
    expect(service.isReady, isTrue);
    service.beginSession();
    final result = await service.detectNv21(fakeFrame(), 0);
    expect(result.detections, isEmpty);
  });

  test(
    'slow inference logs warning and completes without restarting',
    () async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      addTearDown(() {
        debugPrint = previous;
      });
      var loads = 0;
      final service = LocalYoloService(
        modelLoader: () async {
          loads++;
          return ByteData(1);
        },
        workerEntryPoint: fakeWorker,
        slowFrameThreshold: const Duration(milliseconds: 5),
      );
      addTearDown(service.dispose);
      await service.initialize();
      final result = await service.detectNv21(fakeFrame(), 0);
      expect(result.yoloMs, 70);
      expect(loads, 1);
      expect(service.isReady, isTrue);
      expect(logs.any((line) => line.contains('OFFLINE SLOW')), isTrue);
    },
  );

  test('dispose during asset loading leaves no worker', () async {
    final loaded = Completer<ByteData>();
    final service = LocalYoloService(
      modelLoader: () => loaded.future,
      workerEntryPoint: fakeWorker,
    );
    final initialization = service.initialize();
    final checked = expectLater(initialization, throwsStateError);
    final disposal = service.dispose();
    loaded.complete(ByteData(1));
    await checked;
    await disposal;
    expect(service.isReady, isFalse);
    await expectLater(service.initialize(), throwsStateError);
  });
  for (final worker in [exitingWorker, failingWorker]) {
    test('worker initialization failure completes and can retry', () async {
      var loads = 0;
      final service = LocalYoloService(
        modelLoader: () async {
          loads++;
          return ByteData(1);
        },
        workerEntryPoint: worker,
      );
      addTearDown(service.dispose);
      await expectLater(service.initialize(), throwsStateError);
      expect(service.isReady, isFalse);
      await expectLater(service.initialize(), throwsStateError);
      expect(loads, 2);
    });
  }

  test('worker crash releases pending result with error', () async {
    final service = LocalYoloService(
      modelLoader: () async => ByteData(1),
      workerEntryPoint: crashingFrameWorker,
    );
    addTearDown(service.dispose);
    await service.initialize();
    await expectLater(service.detectNv21(fakeFrame(), 0), throwsStateError);
    expect(service.isReady, isFalse);
    expect(service.isBusy, isFalse);
  });
}
