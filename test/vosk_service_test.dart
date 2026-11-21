import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/vosk_service.dart';

class FakeVoskBackend implements VoskBackend {
  final controller = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  int loads = 0, starts = 0, cancels = 0, closes = 0;
  Completer<void>? loadGate, cancelGate;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<Map<String, dynamic>> initialize() async {
    loads++;
    await loadGate?.future;
    return {'load_ms': 15};
  }

  @override
  Future<void> start(int session) async {
    starts++;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {
    cancels++;
    await cancelGate?.future;
  }

  @override
  Future<void> dispose() async {
    closes++;
  }

  void emit(
    int session,
    String type, {
    String text = 'начать',
    int voiced = 20,
  }) => controller.add({
    'session': session,
    'type': type,
    'voiced_frames': voiced,
    'raw': jsonEncode({'text': text, 'partial': text}),
    'audio_ms': 1000,
  });
}

void main() {
  late FakeVoskBackend backend;
  late VoskService service;
  setUp(() {
    backend = FakeVoskBackend();
    service = VoskService(backend: backend);
  });
  tearDown(() async {
    await service.dispose();
    await backend.controller.close();
  });
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'model reused; partial never completes; final consumed exactly once',
    () async {
      final pending = service.startListening();
      await settle();
      var completed = false;
      unawaited(pending.then((_) => completed = true));
      backend.emit(service.session, 'partial');
      await settle();
      expect(completed, false);
      backend.emit(service.session, 'final');
      expect(await pending, 'начать');
      backend.emit(service.session, 'final', text: 'стоп');
      expect(service.rawText, 'начать');
      final second = service.startListening();
      await settle();
      backend.emit(service.session, 'final', text: 'стоп');
      expect(await second, 'стоп');
      expect(backend.loads, 1);
      expect(backend.starts, 2);
    },
  );
  test(
    'TTS invalidates session synchronously and late final cannot execute',
    () async {
      final pending = service.startListening();
      await settle();
      final old = service.session;
      final speaking = service.setSpeaking(true);
      backend.emit(old, 'final');
      expect(await pending, null);
      await speaking;
      expect(await service.startListening(), null);
      await service.setSpeaking(false);
      final next = service.startListening();
      await settle();
      backend.emit(old, 'final');
      backend.emit(service.session, 'final', text: 'закончить');
      expect(await next, 'закончить');
    },
  );
  test('cancel while loading never opens microphone', () async {
    backend.loadGate = Completer<void>();
    final pending = service.startListening();
    await settle();
    await service.cancel();
    backend.loadGate!.complete();
    await settle();
    expect(await pending, null);
    expect(backend.starts, 0);
  });
  test('second start does not overlap microphone', () async {
    final pending = service.startListening();
    await settle();
    expect(await service.startListening(), null);
    expect(backend.starts, 1);
    await service.cancel();
    expect(await pending, null);
  });
  test('new start waits for native cancellation cleanup', () async {
    final pending = service.startListening();
    await settle();
    backend.cancelGate = Completer<void>();
    final cleanup = service.cancel();
    final next = service.startListening();
    await settle();
    expect(backend.starts, 1);
    backend.cancelGate!.complete();
    await cleanup;
    await settle();
    expect(backend.starts, 2);
    backend.emit(service.session, 'final');
    expect(await next, 'начать');
    expect(await pending, null);
  });
  test('silence final is not actionable even if text hallucinated', () async {
    final pending = service.startListening();
    await settle();
    backend.emit(service.session, 'final', voiced: 0);
    expect(await pending, null);
  });
  test(
    'final alternatives retained without promoting lower-ranked commands',
    () async {
      final pending = service.startListening();
      await settle();
      backend.controller.add({
        'session': service.session,
        'type': 'final',
        'voiced_frames': 20,
        'raw': jsonEncode({
          'text': 'не начинай',
          'alternatives': [
            {'text': 'не начинай', 'confidence': 1000},
            {'text': 'начни', 'confidence': 999},
          ],
        }),
      });
      expect(await pending, 'не начинай');
      expect(service.alternatives, ['не начинай', 'начни']);
      final next = service.startListening();
      expect(service.alternatives, isEmpty);
      expect(service.lastMeasurement, isNull);
      await settle();
      await service.cancel();
      expect(await next, null);
    },
  );
  test('dispose is terminal and idempotent', () async {
    final pending = service.startListening();
    await settle();
    await service.dispose();
    expect(await pending, null);
    expect(service.state, VoskState.disposed);
    expect(await service.startListening(), null);
    await service.dispose();
    expect(backend.closes, 1);
  });
  test('error releases microphone; stale results remain rejected', () async {
    final pending = service.startListening();
    await settle();
    final expectation = expectLater(pending, throwsStateError);
    backend.controller.add({
      'session': service.session,
      'type': 'error',
      'message': 'mic denied',
    });
    await expectation;
    await settle();
    expect(service.state, VoskState.error);
    expect(backend.cancels, 1);
  });
}
