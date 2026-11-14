import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Short speech-recognition sessions for voice commands.
/// Not a true, continuous/offline wake-word engine.
class VoiceCommandService {
  final stt.SpeechToText _speech = stt.SpeechToText();

  Future<bool>? _initialization;
  Timer? _finalResultTimer;
  Timer? _watchdogTimer;

  bool _disposed = false;
  bool _active = false;
  bool _completed = false;
  int _sessionId = 0;

  String? _localeId;
  String _lastPartial = '';

  void Function(String)? _onResult;
  void Function(String)? _onPartial;
  void Function(String)? _onError;
  void Function()? _onDone;
  bool Function(String)? _acceptPartial;

  /// FIX: тайминги вынесены в константы.
  static const Duration _watchdogTimeout = Duration(seconds: 18);
  static const Duration _finalResultDelay = Duration(milliseconds: 800);
  static const Duration _listenFor = Duration(seconds: 12);
  static const Duration _pauseFor = Duration(seconds: 3);

  bool get isListening => _active && _speech.isListening;

  Future<bool> initialize() async {
    if (_disposed) return false;
    final pending = _initialization ??= _initializeOnce();
    try {
      final available = await pending;
      if (!available) _initialization = null;
      return available;
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<bool> _initializeOnce() async {
    final available = await _speech.initialize(
      onError: (error) {
        debugPrint('STT ERROR: ${error.errorMsg}');
        _handleEngineError(error.errorMsg);
      },
      onStatus: (status) {
        debugPrint('STT STATUS: $status');
        if (!_active || _completed) return;
        if (status == stt.SpeechToText.doneStatus ||
            status == stt.SpeechToText.notListeningStatus) {
          // FIX: не вызываем _onDone здесь — он будет вызван из _finish*.
          _scheduleFinalResult(_sessionId);
        }
      },
      options: [stt.SpeechToText.androidNoBluetooth],
    );

    if (!available) return false;

    final locales = await _speech.locales();
    _localeId = null;
    for (final locale in locales) {
      if (locale.localeId.toLowerCase().startsWith('ru')) {
        _localeId = locale.localeId;
        break;
      }
    }
    debugPrint('STT Russian locale: $_localeId');
    return true;
  }

  /// If [acceptPartial] returns true, completes immediately on that partial
  /// transcript. It avoids losing recognized wake phrases when Android never
  /// sends a final result.
  Future<void> listen({
    required void Function(String text) onResult,
    required void Function(String text) onPartial,
    required void Function(String error) onError,
    required void Function() onDone,
    bool Function(String text)? acceptPartial,
  }) async {
    if (_disposed) return;
    if (_active) await cancel();

    bool available;
    try {
      available = await initialize();
    } catch (error) {
      onError('Инициализация распознавания: $error');
      // FIX: гарантируем onDone даже при ошибке инициализации.
      onDone();
      return;
    }

    if (_disposed) return;
    if (!available) {
      onError(
        'Распознавание речи недоступно. Проверьте разрешение на микрофон.',
      );
      onDone();
      return;
    }
    if (_localeId == null) {
      onError('Русский язык распознавания не установлен на телефоне.');
      onDone();
      return;
    }

    final session = ++_sessionId;
    _active = true;
    _completed = false;
    _lastPartial = '';
    _onResult = onResult;
    _onPartial = onPartial;
    _onError = onError;
    _onDone = onDone;
    _acceptPartial = acceptPartial;

    _watchdogTimer?.cancel();
    // FIX: watchdog должен быть больше listenFor + pauseFor + запас.
    _watchdogTimer = Timer(_watchdogTimeout, () {
      if (!_isCurrent(session)) return;
      debugPrint('STT WATCHDOG: ending recognition session');
      unawaited(_endTimedSession(session));
    });

    try {
      await _speech.listen(
        onResult: (result) {
          if (!_isCurrent(session)) return;
          final words = result.recognizedWords.trim();
          if (words.isNotEmpty) {
            _lastPartial = words;
            debugPrint(
              'STT ${result.finalResult ? 'FINAL' : 'PARTIAL'}: $words',
            );
            _onPartial?.call(words);

            if (!result.finalResult && _acceptPartial?.call(words) == true) {
              _finishWithText(session, words);
              return;
            }
          }

          if (result.finalResult) {
            if (words.isNotEmpty) {
              _finishWithText(session, words);
            } else {
              _scheduleFinalResult(session);
            }
          }
        },
        listenOptions: stt.SpeechListenOptions(
          localeId: _localeId,
          listenFor: _listenFor,
          pauseFor: _pauseFor,
          partialResults: true,
          listenMode: stt.ListenMode.confirmation,
        ),
      );
      debugPrint('STT STARTED');
    } catch (error) {
      _finishWithError(session, 'Ошибка запуска микрофона: $error');
    }
  }

  bool _isCurrent(int session) =>
      !_disposed && _active && !_completed && session == _sessionId;

  Future<void> _endTimedSession(int session) async {
    if (!_isCurrent(session)) return;
    try {
      await _speech.stop();
    } catch (error) {
      debugPrint('STT stop error: $error');
    }
    _scheduleFinalResult(session);
  }

  void _handleEngineError(String message) {
    if (!_active || _completed) return;
    final session = _sessionId;
    if (!_isCurrent(session)) return;
    if (_lastPartial.trim().isNotEmpty) {
      _scheduleFinalResult(session);
    } else {
      _finishWithError(session, 'Распознавание: $message');
    }
  }

  void _scheduleFinalResult(int session) {
    if (!_isCurrent(session)) return;
    _finalResultTimer?.cancel();
    _finalResultTimer = Timer(_finalResultDelay, () {
      if (!_isCurrent(session)) return;
      if (_lastPartial.trim().isNotEmpty) {
        debugPrint('STT FALLBACK: $_lastPartial');
        _finishWithText(session, _lastPartial);
      } else {
        _finishWithError(session, 'Нет распознанной речи (no_match/timeout)');
      }
    });
  }

  // FIX: всегда вызываем onDone, даже если результат потерян из-за новой сессии.
  void _finishWithText(int session, String message) {
    if (!_isCurrent(session)) return;
    _completed = true;
    _active = false;
    _cancelTimers();
    final onResult = _onResult;
    final onDone = _onDone;
    _clearCallbacks();
    unawaited(() async {
      await _releaseRecognizer();
      if (_disposed) return;
      if (session == _sessionId) {
        debugPrint('STT RECOGNIZED: $message');
        onResult?.call(message);
      }
      onDone?.call();
    }());
  }

  void _finishWithError(int session, String message) {
    if (!_isCurrent(session)) return;
    _completed = true;
    _active = false;
    _cancelTimers();
    final onError = _onError;
    final onDone = _onDone;
    _clearCallbacks();
    unawaited(() async {
      await _releaseRecognizer();
      if (_disposed) return;
      if (session == _sessionId) {
        debugPrint('STT FAILURE: $message');
        onError?.call(message);
      }
      onDone?.call();
    }());
  }

  Future<void> _releaseRecognizer() async {
    try {
      await _speech.cancel();
    } catch (error) {
      debugPrint('STT cancel error: $error');
    }
  }

  void _cancelTimers() {
    _finalResultTimer?.cancel();
    _finalResultTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _clearCallbacks() {
    _onResult = null;
    _onPartial = null;
    _onError = null;
    _onDone = null;
    _acceptPartial = null;
  }

  Future<void> cancel() async {
    final onDone = _onDone;
    ++_sessionId;
    _active = false;
    _completed = true;
    _lastPartial = '';
    _cancelTimers();
    _clearCallbacks();
    await _releaseRecognizer();
    onDone?.call();
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }
}
