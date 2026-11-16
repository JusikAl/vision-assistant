import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:open_wake_word/open_wake_word.dart';
import 'package:record/record.dart';

class WakeWordService {
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _subscription;
  final List<int> _buffer = [];

  Future<void>? _stopFuture;
  Future<void>? _initFuture;
  Future<void>? _startFuture;

  bool _initialized = false;
  bool _listening = false;
  bool _triggered = false;
  bool _disposed = false;

  int _generation = 0;

  DateTime _lastActivation = DateTime.fromMillisecondsSinceEpoch(0);

  static const String melModel = 'assets/models/melspectrogram.onnx';
  static const String embeddingModel = 'assets/models/embedding_model.onnx';
  static const String wakeModel = 'assets/models/hey_jarvis_v0.1.onnx';

  static const int sampleRate = 16000;
  static const int frameSamples = 1280;
  static const int frameBytes = frameSamples * 2;

  // Максимум фреймов в буфере. Если инференс медленнее реального времени,
  // старые фреймы отбрасываются, чтобы не росла задержка.
  static const int maxBufferedFrames = 8; // ~640 мс аудио
  static const int maxBufferBytes = maxBufferedFrames * frameBytes;

  static const Duration cooldown = Duration(seconds: 2);

  bool get isListening => _listening;

  Future<void> initialize() {
    if (_disposed) {
      return Future.error(StateError('WakeWordService already disposed'));
    }
    if (_initialized) return Future.value();

    return _initFuture ??= _initializeInternal().whenComplete(() {
      _initFuture = null;
    });
  }

  Future<void> _initializeInternal() async {
    if (_initialized) return;

    final success = await OpenWakeWord.init(
      melModelAssetPath: melModel,
      embModelAssetPath: embeddingModel,
      wwModelAssetPaths: [wakeModel],
    );

    if (!success) {
      // Частичная инициализация могла произойти — чистим.
      try {
        OpenWakeWord.destroy();
      } catch (_) {}
      throw StateError('OpenWakeWord initialization failed');
    }

    if (_disposed) {
      try {
        OpenWakeWord.destroy();
      } catch (_) {}
      return;
    }

    _initialized = true;
    if (kDebugMode) debugPrint('WAKE: Engine initialized');
  }

  Future<void> start({
    required Future<void> Function() onDetected,
    void Function(Object error)? onError,
  }) {
    if (_disposed) return Future.value();
    // Дедупликация параллельных start()
    return _startFuture ??=
        _startInternal(onDetected: onDetected, onError: onError).whenComplete(
          () {
            _startFuture = null;
          },
        );
  }

  Future<void> _startInternal({
    required Future<void> Function() onDetected,
    void Function(Object error)? onError,
  }) async {
    if (_disposed) return;

    if (_stopFuture != null) {
      await _stopFuture;
    }

    if (_disposed || _listening) return;

    final generation = _generation;
    await initialize();

    if (_disposed || generation != _generation) return;

    final hasPermission = await _recorder.hasPermission();
    if (_disposed || generation != _generation) return;
    if (!hasPermission) {
      throw StateError('Microphone permission denied');
    }

    _buffer.clear();
    _triggered = false;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );

    if (_disposed || generation != _generation) {
      try {
        await _recorder.stop();
      } catch (_) {}
      return;
    }

    _listening = true;

    _subscription = stream.listen(
      (bytes) {
        if (!_listening || _triggered || generation != _generation) {
          return;
        }

        try {
          _buffer.addAll(bytes);

          // Защита от роста буфера: если пришло больше, чем успеваем обработать,
          // режем самые старые байты (кратно frameBytes).
          if (_buffer.length > maxBufferBytes) {
            final drop =
                ((_buffer.length - maxBufferBytes) ~/ frameBytes) * frameBytes;
            if (drop > 0) {
              _buffer.removeRange(0, drop);
            }
          }

          int processed = 0;

          while (_buffer.length - processed >= frameBytes) {
            final samples = Int16List(frameSamples);

            for (int i = 0; i < frameSamples; i++) {
              final index = processed + i * 2;
              final raw = _buffer[index] | (_buffer[index + 1] << 8);
              samples[i] = raw >= 0x8000 ? raw - 0x10000 : raw;
            }

            processed += frameBytes;

            OpenWakeWord.processAudio(samples);

            if (OpenWakeWord.isActivated()) {
              final now = DateTime.now();

              if (now.difference(_lastActivation) < cooldown) {
                continue;
              }

              _lastActivation = now;
              _triggered = true;

              if (kDebugMode) debugPrint('WAKE: Hey Jarvis detected');

              unawaited(() async {
                try {
                  await stop();
                  if (!_disposed) {
                    await onDetected();
                  }
                } catch (error) {
                  final handler = onError;
                  if (handler != null) {
                    handler(error);
                  }
                }
              }());

              break;
            }
          }

          if (processed > 0) {
            _buffer.removeRange(0, processed);
          }
        } catch (error) {
          debugPrint('WAKE PROCESS ERROR: $error');
          final handler = onError;
          if (handler != null) {
            handler(error);
          }
          unawaited(stop());
        }
      },
      onError: (Object error) {
        debugPrint('WAKE STREAM ERROR: $error');
        final handler = onError;
        if (handler != null) {
          handler(error);
        }
        unawaited(stop());
      },
      cancelOnError: true,
    );

    if (kDebugMode) debugPrint('WAKE: Listening started');
  }

  Future<void> stop() {
    return _stopFuture ??= _stopInternal().whenComplete(() {
      _stopFuture = null;
    });
  }

  Future<void> _stopInternal() async {
    ++_generation;

    _listening = false;
    _triggered = false;
    _lastActivation = DateTime.fromMillisecondsSinceEpoch(0);

    final subscription = _subscription;
    _subscription = null;

    if (subscription != null) {
      await subscription.cancel();
    }

    try {
      await _recorder.stop();
    } catch (error) {
      debugPrint('WAKE STOP ERROR: $error');
    }

    _buffer.clear();

    if (kDebugMode) debugPrint('WAKE: Listening stopped');
  }

  Future<void> dispose() async {
    if (_disposed) return;

    _disposed = true;

    await stop();

    final startFuture = _startFuture;
    if (startFuture != null) {
      try {
        await startFuture;
      } catch (_) {}
    }

    final initFuture = _initFuture;
    if (initFuture != null) {
      try {
        await initFuture;
      } catch (_) {}
    }

    try {
      await _recorder.dispose();
    } catch (_) {}

    if (_initialized) {
      try {
        OpenWakeWord.destroy();
      } catch (_) {}
      _initialized = false;
    }
  }
}
