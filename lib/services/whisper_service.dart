import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../voice_command_service.dart' show VoiceState;

abstract interface class WhisperBackend {
  Future<Map<String, dynamic>> initialize();
  Future<Map<String, dynamic>> transcribe(Uint8List pcm);
  Future<void> cancel();
  Future<void> dispose();
}

class NativeWhisperBackend implements WhisperBackend {
  static const channel = MethodChannel('navigation/whisper');
  @override
  Future<Map<String, dynamic>> initialize() async => Map<String, dynamic>.from(
    await channel.invokeMethod('initialize') as Map,
  );
  @override
  Future<Map<String, dynamic>> transcribe(Uint8List pcm) async =>
      Map<String, dynamic>.from(
        await channel.invokeMethod('transcribe', {'pcm': pcm}) as Map,
      );
  @override
  Future<void> cancel() => channel.invokeMethod<void>('cancel');
  @override
  Future<void> dispose() => channel.invokeMethod<void>('dispose');
}

abstract interface class CommandRecorder {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}

class PcmCommandRecorder implements CommandRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  @override
  Future<bool> hasPermission() => _recorder.hasPermission();
  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      audioInterruption: AudioInterruptionMode.none,
    ),
  );
  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Button and future wake-word activations use this same bounded PCM session.
/// Native work runs on a single background Android executor, never the UI thread.
class WhisperService {
  WhisperService({
    WhisperBackend? backend,
    CommandRecorder? recorder,
    this.inferenceTimeout = const Duration(seconds: 20),
  }) : _backend = backend ?? NativeWhisperBackend(),
       _recorder = recorder ?? PcmCommandRecorder();
  final WhisperBackend _backend;
  final CommandRecorder _recorder;
  final Duration inferenceTimeout;
  Future<void>? _initialization, _nativeWork;
  Future<void>? _audio;
  StreamSubscription<Uint8List>? _subscription;
  Completer<String?>? _result;
  Timer? _deadline;
  final List<int> _pcm = [];
  int _generation = 0;
  bool _disposed = false, _speaking = false;
  bool _audioUnavailable = false;
  VoiceState state = VoiceState.idle;
  void Function(VoiceState)? onStateChanged;
  double? loadMs, recordingMs, recognitionMs, endToResultMs;
  double? averageLogProbability, noSpeechProbability;
  void Function()? onMeasured;

  void _state(VoiceState value) {
    state = value;
    onStateChanged?.call(value);
  }

  bool _current(int id) => !_disposed && !_speaking && id == _generation;
  bool get isListening => state == VoiceState.listening;
  bool get isProcessing => _nativeWork != null;

  Future<void> initialize() {
    if (_disposed) return Future.error(StateError('Whisper disposed'));
    return _initialization ??= _backend
        .initialize()
        .then((metrics) {
          loadMs = (metrics['load_ms'] as num).toDouble();
          debugPrint('WHISPER LOAD load_ms=$loadMs');
        })
        .onError((Object e, StackTrace stack) {
          _initialization = null;
          Error.throwWithStackTrace(e, stack);
        });
  }

  Future<void> _serializeAudio(Future<void> Function() action) {
    final next = _audio == null
        ? Future<void>.sync(action)
        : _audio!.then((_) => action());
    _audio = next.catchError((Object _) {});
    return next;
  }

  Future<String?> startListening() {
    if (_audioUnavailable) {
      return Future.error(
        StateError('Микрофон не удалось освободить. Перезапустите приложение'),
      );
    }
    if (_disposed || _speaking || _result != null || _nativeWork != null) {
      return Future.value(null);
    }
    final result = Completer<String?>();
    _result = result;
    final id = ++_generation;
    _state(VoiceState.processing);
    unawaited(_begin(id));
    return result.future;
  }

  Future<void> _begin(int id) async {
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Нет разрешения на микрофон');
      }
      if (!_current(id)) return;
      await initialize();
      if (!_current(id)) return;
      await _serializeAudio(() async {
        if (!_current(id)) return;
        final stream = await _recorder.start();
        if (!_current(id)) {
          await _recorder.stop();
          return;
        }
        _pcm.clear();
        _state(VoiceState.listening);
        _subscription = stream.listen(
          (bytes) {
            if (!_current(id) || !isListening) return;
            _pcm.addAll(bytes.take(math.max(0, 160000 - _pcm.length)));
            if (_pcm.length >= 160000 || _endedBySilence(_pcm)) {
              unawaited(stopListening());
            }
          },
          onError: (Object error) {
            unawaited(_fail(id, error));
          },
          onDone: () {
            if (_current(id) && isListening) {
              unawaited(_fail(id, StateError('Запись прервана')));
            }
          },
        );
        _deadline = Timer(const Duration(seconds: 5), () {
          unawaited(stopListening());
        });
      });
    } catch (error) {
      await _fail(id, error);
    }
  }

  // Frame RMS is an endpoint gate, not a claim of speech identity. Whisper's
  // no-speech/logprob checks and the exact command parser are additional gates.
  static int _voicedFrames(List<int> pcm) {
    var voiced = 0;
    for (var offset = 0; offset + 640 <= pcm.length; offset += 640) {
      if (_rms(pcm, offset) >= .004) voiced++;
    }
    return voiced;
  }

  static double _rms(List<int> pcm, int offset) {
    var square = 0.0;
    for (var i = offset; i < offset + 640; i += 2) {
      var value = pcm[i] | (pcm[i + 1] << 8);
      if (value >= 32768) value -= 65536;
      square += (value / 32768) * (value / 32768);
    }
    return math.sqrt(square / 320);
  }

  static bool _endedBySilence(List<int> pcm) {
    if (pcm.length < 32000 || _voicedFrames(pcm) < 8) return false;
    final start = (pcm.length ~/ 640 - 40) * 640;
    if (start < 0) return false;
    for (var i = start; i + 640 <= pcm.length; i += 640) {
      if (_rms(pcm, i) >= .004) return false;
    }
    return true;
  }

  Future<void> stopListening() async {
    if (!isListening) return;
    final id = _generation;
    _state(VoiceState.processing);
    final watch = Stopwatch()..start();
    _deadline?.cancel();
    await _releaseAudio();
    if (!_current(id)) return;
    final pcm = Uint8List.fromList(_pcm);
    _pcm.clear();
    recordingMs = pcm.length / 32;
    if (pcm.length < 6400 || pcm.length.isOdd || _voicedFrames(pcm) < 8) {
      _complete(id, null);
      return;
    }
    try {
      final text = await transcribe(pcm);
      endToResultMs = watch.elapsedMicroseconds / 1000;
      if (_current(id)) {
        debugPrint(
          'WHISPER PERF recording_ms=$recordingMs inference_ms=$recognitionMs end_to_result_ms=$endToResultMs',
        );
        onMeasured?.call();
        _complete(id, text);
      }
    } catch (error) {
      await _fail(id, error);
    }
  }

  /// Accepts only bounded mono PCM16/16kHz. Also used by offline device fixtures.
  Future<String?> transcribe(Uint8List pcm) async {
    if (_disposed || _speaking || _nativeWork != null) return null;
    if (pcm.length < 6400 || pcm.length > 160000 || pcm.length.isOdd) {
      throw ArgumentError('Expected 0.2–5 seconds of mono PCM16/16kHz');
    }
    if (_voicedFrames(pcm) < 8) return null;
    final id = _generation;
    await initialize();
    if (!_current(id) || _nativeWork != null) return null;
    recognitionMs = averageLogProbability = noSpeechProbability = null;
    final pending = _backend.transcribe(pcm);
    final work = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _nativeWork = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_nativeWork, work)) _nativeWork = null;
      }),
    );
    try {
      final output = await pending.timeout(inferenceTimeout);
      if (!_current(id)) return null;
      recognitionMs = (output['inference_ms'] as num).toDouble();
      final logprob = (output['avg_logprob'] as num).toDouble();
      final noSpeech = (output['no_speech_prob'] as num).toDouble();
      averageLogProbability = logprob;
      noSpeechProbability = noSpeech;
      if (!logprob.isFinite ||
          !noSpeech.isFinite ||
          logprob < -1 ||
          logprob > 0 ||
          noSpeech < 0 ||
          noSpeech > .6) {
        return null;
      }
      final text = (output['text'] as String).trim();
      return text.isEmpty ? null : text;
    } on TimeoutException {
      await _backend.cancel();
      rethrow;
    }
  }

  void _complete(int id, String? text) {
    if (!_current(id)) return;
    final result = _result;
    _result = null;
    _state(VoiceState.idle);
    if (result != null && !result.isCompleted) result.complete(text);
  }

  Future<void> _fail(int id, Object error) async {
    if (!_current(id)) return;
    final result = _result;
    _result = null;
    final failedGeneration = ++_generation;
    _deadline?.cancel();
    try {
      await _releaseAudio();
    } catch (_) {
      /* preserve original error */
    }
    if (failedGeneration == _generation) {
      _pcm.clear();
      if (!_disposed) _state(VoiceState.error);
    }
    if (result != null && !result.isCompleted) result.completeError(error);
  }

  Future<void> _releaseAudio() => _serializeAudio(() async {
    final subscription = _subscription;
    _subscription = null;
    // Cancel delivery immediately; the recorder's stop acknowledgement owns
    // microphone release. Do not delay native stop behind stream cleanup.
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    try {
      await _recorder.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      _audioUnavailable = true;
      rethrow;
    }
  });
  Future<void> cancel() async {
    final cancelledGeneration = ++_generation;
    _deadline?.cancel();
    final result = _result;
    _result = null;
    if (result != null && !result.isCompleted) result.complete(null);
    // Native cancellation is immediate; never wait for an inference to finish
    // before allowing a critical warning to take the speaker.
    unawaited(_backend.cancel().catchError((Object _) {}));
    try {
      await _releaseAudio();
    } catch (_) {
      /* TTS may still take priority */
    }
    if (cancelledGeneration == _generation) {
      _pcm.clear();
      if (!_disposed) _state(_speaking ? VoiceState.speaking : VoiceState.idle);
    }
  }

  Future<void> setSpeaking(bool value) async {
    _speaking = value;
    if (value) await cancel();
    if (!_disposed) _state(value ? VoiceState.speaking : VoiceState.idle);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    try {
      await _recorder.dispose().timeout(const Duration(seconds: 2));
    } catch (error) {
      debugPrint('Whisper recorder cleanup: $error');
    } finally {
      try {
        await _backend.dispose();
      } catch (error) {
        debugPrint('Whisper engine cleanup: $error');
      }
    }
  }
}
