import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/whisper_service.dart';
import 'package:yolo_live_detection/voice_command_service.dart';

class FakeBackend implements WhisperBackend {
  int loads = 0, runs = 0, cancels = 0, frees = 0;
  Completer<Map<String, dynamic>>? loadGate, runGate;
  Map<String, dynamic> output = {
    'text': 'стоп',
    'avg_logprob': -.2,
    'no_speech_prob': .01,
    'inference_ms': 12,
  };
  @override
  Future<Map<String, dynamic>> initialize() async {
    loads++;
    return await loadGate?.future ?? {'load_ms': 10};
  }

  @override
  Future<Map<String, dynamic>> transcribe(Uint8List pcm) async {
    runs++;
    return await runGate?.future ?? output;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async {
    frees++;
  }
}

class FakeRecorder implements CommandRecorder {
  final stream = StreamController<Uint8List>.broadcast();
  bool permission = true;
  int starts = 0, stops = 0, frees = 0;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  bool failStop = false;
  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await startGate?.future;
    return stream.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    if (failStop) throw StateError('Recorder stop failed');
  }

  @override
  Future<void> dispose() async {
    frees++;
    await stream.close();
  }
}

Uint8List voiced([int frames = 20]) {
  final data = ByteData(frames * 640);
  for (var i = 0; i < data.lengthInBytes; i += 2) {
    data.setInt16(i, i % 4 == 0 ? 2000 : -2000, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  late FakeBackend backend;
  late FakeRecorder recorder;
  late WhisperService service;
  void resetService() {
    backend = FakeBackend();
    recorder = FakeRecorder();
    service = WhisperService(backend: backend, recorder: recorder);
  }

  setUp(resetService);
  tearDown(() async => service.dispose());
  void whisperTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      resetService();
      try {
        await body(tester);
      } finally {
        await service.dispose();
        await tester.pump();
      }
    });
  }

  whisperTest(
    'five second recording is bounded; model reused across commands',
    (tester) async {
      final result = service.startListening();
      await tester.pump();
      expect(service.state, VoiceState.listening);
      recorder.stream.add(voiced());
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(await result, 'стоп');
      expect(backend.runs, 1);
      expect(recorder.stops, 1);
      final second = service.transcribe(voiced());
      await tester.pump();
      await second;
      expect(backend.loads, 1);
    },
  );
  whisperTest('silence has no transcript and never calls native inference', (
    tester,
  ) async {
    final result = service.startListening();
    await tester.pump();
    recorder.stream.add(Uint8List(160000));
    await tester.pump();
    expect(await result, isNull);
    expect(backend.runs, 0);
  });
  whisperTest(
    'speech ends after 800ms of silence without waiting five seconds',
    (tester) async {
      final result = service.startListening();
      await tester.pump();
      recorder.stream.add(voiced());
      recorder.stream.add(Uint8List(25600));
      await tester.pump();
      expect(await result, 'стоп');
    },
  );
  whisperTest('denied microphone does not initialize model or open recording', (
    tester,
  ) async {
    recorder.permission = false;
    final result = service.startListening();
    final error = expectLater(result, throwsStateError);
    await tester.pump();
    await error;
    expect(backend.loads, 0);
    expect(recorder.starts, 0);
    expect(service.state, VoiceState.error);
  });
  whisperTest('cancel during model loading never opens microphone', (
    tester,
  ) async {
    backend.loadGate = Completer<Map<String, dynamic>>();
    final first = service.startListening();
    await tester.pump();
    await service.cancel();
    backend.loadGate!.complete({'load_ms': 30});
    await tester.pump();
    expect(await first, isNull);
    expect(recorder.starts, 0);
  });
  whisperTest('failed model initialization is reported and can be retried', (
    tester,
  ) async {
    backend.loadGate = Completer<Map<String, dynamic>>();
    final first = service.startListening();
    final failure = expectLater(first, throwsStateError);
    await tester.pump();
    backend.loadGate!.completeError(StateError('Missing model'));
    await tester.pump();
    await failure;
    expect(service.state, VoiceState.error);
    expect(recorder.starts, 0);
    backend.loadGate = null;
    final retry = service.startListening();
    await tester.pump();
    expect(service.state, VoiceState.listening);
    expect(backend.loads, 2);
    await service.cancel();
    expect(await retry, isNull);
  });
  whisperTest('repeated button activation cannot create two recorders', (
    tester,
  ) async {
    final first = service.startListening();
    await tester.pump();
    expect(await service.startListening(), isNull);
    expect(recorder.starts, 1);
    await service.cancel();
    expect(await first, isNull);
  });
  whisperTest(
    'cancel while recorder opens releases it and suppresses transcript',
    (tester) async {
      recorder.startGate = Completer<void>();
      final result = service.startListening();
      await tester.pump();
      final cancel = service.cancel();
      recorder.startGate!.complete();
      await tester.pump();
      await cancel;
      expect(await result, isNull);
      expect(recorder.stops, greaterThan(0));
    },
  );
  whisperTest('TTS owns audio and cancels pending native result', (
    tester,
  ) async {
    backend.runGate = Completer<Map<String, dynamic>>();
    final result = service.startListening();
    await tester.pump();
    recorder.stream.add(voiced());
    await tester.pump();
    final ending = service.stopListening();
    await tester.pump();
    await service.setSpeaking(true);
    expect(await result, isNull);
    expect(service.state, VoiceState.speaking);
    expect(await service.startListening(), isNull);
    backend.runGate!.complete(backend.output);
    await tester.pump();
    await ending;
    expect(backend.cancels, greaterThan(0));
    await service.setSpeaking(false);
    expect(service.state, VoiceState.idle);
  });
  test('single native inference, cancelled late result ignored', () async {
    backend.runGate = Completer<Map<String, dynamic>>();
    final pending = service.transcribe(voiced());
    await Future<void>.delayed(Duration.zero);
    expect(await service.transcribe(voiced()), isNull);
    await service.cancel();
    expect(await service.transcribe(voiced()), isNull);
    backend.runGate!.complete(backend.output);
    expect(await pending, isNull);
    expect(backend.runs, 1);
  });
  test(
    'unconfident/no-speech and malformed outputs cannot execute commands',
    () async {
      for (final pair in [
        [-2.0, .01],
        [-.2, .9],
        [double.nan, .01],
        [-.2, -1.0],
      ]) {
        backend.output['avg_logprob'] = pair[0];
        backend.output['no_speech_prob'] = pair[1];
        expect(await service.transcribe(voiced()), isNull);
      }
      expect(() => service.transcribe(Uint8List(160002)), throwsArgumentError);
      expect(await service.transcribe(Uint8List(16000)), isNull);
    },
  );
  whisperTest('stream interruption is an error, not a partial command', (
    tester,
  ) async {
    final pending = service.startListening();
    final error = expectLater(pending, throwsStateError);
    await tester.pump();
    recorder.stream.add(voiced());
    await recorder.stream.close();
    await tester.pump();
    await error;
    expect(backend.runs, 0);
  });
  whisperTest('native timeout cancels without queuing further inferences', (
    tester,
  ) async {
    backend.runGate = Completer<Map<String, dynamic>>();
    final pending = service.transcribe(voiced());
    final error = expectLater(pending, throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await error;
    expect(backend.cancels, 1);
    expect(await service.transcribe(voiced()), isNull);
    backend.runGate!.complete(backend.output);
    await tester.pump();
  });
  whisperTest('dispose invalidates recording and frees both resources once', (
    tester,
  ) async {
    final pending = service.startListening();
    await tester.pump();
    await service.dispose();
    expect(await pending, isNull);
    await service.dispose();
    expect(recorder.frees, 1);
    expect(backend.frees, 1);
    expect(await service.startListening(), isNull);
  });
  whisperTest(
    'cancel acknowledgement cannot overwrite a newer listening session',
    (tester) async {
      final first = service.startListening();
      await tester.pump();
      recorder.stopGate = Completer<void>();
      final cancelling = service.cancel();
      final second = service.startListening();
      await tester.pump();
      recorder.stopGate!.complete();
      recorder.stopGate = null;
      await tester.pump();
      await cancelling;
      expect(await first, isNull);
      expect(service.state, VoiceState.listening);
      await service.cancel();
      expect(await second, isNull);
    },
  );
  whisperTest(
    'failed microphone release blocks new capture but lets TTS proceed',
    (tester) async {
      final result = service.startListening();
      await tester.pump();
      recorder.failStop = true;
      await service.setSpeaking(true);
      expect(await result, isNull);
      expect(service.state, VoiceState.speaking);
      await expectLater(service.startListening(), throwsStateError);
    },
  );
}
