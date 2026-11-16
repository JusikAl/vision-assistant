import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:yolo_live_detection/voice_command_service.dart';

class FakeSpeech extends stt.SpeechToText {
  FakeSpeech() : super.withMethodChannel();
  Completer<bool>? initializationGate;
  int initializations = 0, starts = 0, cancels = 0;
  bool listening = false;
  stt.SpeechResultListener? result;
  stt.SpeechStatusListener? status;
  @override
  bool get isListening => listening;
  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    initializations++;
    status = onStatus;
    return await initializationGate?.future ?? true;
  }

  @override
  Future<List<stt.LocaleName>> locales() async => [
    stt.LocaleName('ru_RU', 'Russian'),
  ];
  @override
  Future listen({
    stt.SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    stt.SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    stt.ListenMode listenMode = stt.ListenMode.confirmation,
    dynamic sampleRate = 0,
    stt.SpeechListenOptions? listenOptions,
  }) async {
    starts++;
    listening = true;
    result = onResult;
    expect(listenOptions?.listenMode, stt.ListenMode.dictation);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    listening = false;
  }

  @override
  Future<void> stop() async {
    listening = false;
  }

  void emit(String words, {bool finalResult = true}) {
    result?.call(
      SpeechRecognitionResult.fromJson({
        'alternates': [
          {'recognizedWords': words, 'confidence': .9},
        ],
        'resultType': finalResult ? 2 : 0,
      }),
    );
  }
}

void main() {
  late FakeSpeech native;
  late VoiceCommandService service;
  late List<String> results;
  late List<String> errors;
  late int done;
  setUp(() {
    native = FakeSpeech();
    service = VoiceCommandService(speech: native);
    results = [];
    errors = [];
    done = 0;
  });
  Future<void> listen() => service.listen(
    onResult: results.add,
    onPartial: (_) {},
    onError: errors.add,
    onDone: () => done++,
  );
  tearDown(() async => service.dispose());

  test('cancel during initialization prevents microphone start', () async {
    native.initializationGate = Completer<bool>();
    final pending = listen();
    await Future<void>.delayed(Duration.zero);
    final stopped = service.cancel();
    native.initializationGate!.complete(true);
    await pending;
    await stopped;
    expect(native.starts, 0);
    expect(results, isEmpty);
  });
  test('latest concurrent request wins, recognizer initialized once', () async {
    native.initializationGate = Completer<bool>();
    final first = listen();
    await Future<void>.delayed(Duration.zero);
    final second = listen();
    native.initializationGate!.complete(true);
    await first;
    await second;
    expect(native.starts, 1);
    expect(native.initializations, 1);
    expect(service.state, VoiceState.listening);
  });
  test(
    'final result delivered once and stale callback ignored after restart',
    () async {
      await listen();
      final stale = native.result;
      native.emit('стоп');
      await Future<void>.delayed(Duration.zero);
      expect(results, ['стоп']);
      expect(done, 1);
      await listen();
      stale?.call(
        SpeechRecognitionResult.fromJson({
          'alternates': [
            {'recognizedWords': 'начать', 'confidence': .9},
          ],
          'resultType': 2,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(results, ['стоп']);
      expect(native.initializations, 1);
    },
  );
  test(
    'TTS blocks recognition and cancelled transcripts cannot execute',
    () async {
      await listen();
      final stale = native.result;
      await service.setSpeaking(true);
      expect(service.state, VoiceState.speaking);
      await listen();
      expect(native.starts, 1);
      stale?.call(
        SpeechRecognitionResult.fromJson({
          'alternates': [
            {'recognizedWords': 'стоп', 'confidence': .9},
          ],
          'resultType': 2,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(results, isEmpty);
      await service.setSpeaking(false);
      await listen();
      expect(native.starts, 2);
    },
  );
  test(
    'notListening falls back to last partial without restart loop',
    () async {
      await listen();
      native.emit('что впереди', finalResult: false);
      native.status?.call(stt.SpeechToText.notListeningStatus);
      await Future<void>.delayed(const Duration(milliseconds: 850));
      expect(results, ['что впереди']);
      expect(done, 1);
      expect(native.starts, 1);
    },
  );
}
