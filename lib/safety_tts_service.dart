import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class SafetyAlert {
  final String key;
  final String text;
  final int priority;

  const SafetyAlert({
    required this.key,
    required this.text,
    required this.priority,
  });

  factory SafetyAlert.fromJson(Map<String, dynamic> json) {
    return SafetyAlert(
      key: json['key']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      // FIX: ограничиваем приоритет разумным диапазоном.
      priority: ((json['priority'] as num?)?.toInt() ?? 1).clamp(1, 3),
    );
  }
}

/// One TTS engine for automatic YOLO warnings and user-requested responses.
class SafetyTtsService {
  final FlutterTts _tts = FlutterTts();
  final Map<String, int> _seenFrames = {};
  final Map<String, DateTime> _lastSpoken = {};

  Future<void>? _initialization;

  SafetyAlert? _current;
  SafetyAlert? _pending;

  /// FIX: сигнал «появился новый _pending», чтобы loop не крутился вхолостую
  /// и не запускался повторно из onFrame.
  Completer<void>? _pendingSignal;

  /// FIX: единственный мьютекс цикла. Пока он не завершён — новый цикл не стартует.
  Future<void>? _loopFuture;

  /// FIX: сериализация stop() без линейного роста цепочки.
  Completer<void>? _stopCompleter;

  bool _enabled = true;
  bool _disposed = false;
  bool _manualSpeaking = false;
  int _generation = 0;

  static const int requiredFrames = 2;

  /// FIX: кулдаун вынесен в константы, чтобы не дублировать логику.
  static const Duration _cooldownHigh = Duration(seconds: 12);
  static const Duration _cooldownMedium = Duration(seconds: 20);
  static const Duration _cooldownLow = Duration(seconds: 30);

  /// FIX: чистка _lastSpoken от старых записей.
  static const Duration _lastSpokenTtl = Duration(minutes: 5);
  static const Duration _lastSpokenCleanupInterval = Duration(minutes: 1);
  DateTime _lastCleanup = DateTime.now();

  bool get enabled => _enabled;
  bool get isSpeaking => _loopFuture != null || _manualSpeaking;
  String get currentText => _current?.text ?? '';

  Future<void> initialize() => _initialization ??= _setup();

  Future<void> _setup() async {
    _tts.setErrorHandler((message) {
      debugPrint('TTS ENGINE ERROR: $message');
    });
    try {
      await _tts.setLanguage('ru-RU');
      await _tts.setSpeechRate(0.50);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);
      debugPrint('Safety TTS initialized');
    } catch (error) {
      debugPrint('TTS initialization error: $error');
      // FIX: сбрасываем кеш инициализации, чтобы можно было повторить.
      _initialization = null;
      rethrow;
    }
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    _enabled = value;
    if (!value) {
      unawaited(stop());
    }
  }

  Duration _cooldownFor(SafetyAlert alert) {
    if (alert.priority >= 3) return _cooldownHigh;
    if (alert.priority == 2) return _cooldownMedium;
    return _cooldownLow;
  }

  void onFrame(List<dynamic> rawAlerts) {
    if (!_enabled || _disposed || _manualSpeaking) return;

    final visible = <String, SafetyAlert>{};
    for (final item in rawAlerts) {
      if (item is! Map) continue;
      try {
        final alert = SafetyAlert.fromJson(Map<String, dynamic>.from(item));
        if (alert.key.isNotEmpty && alert.text.isNotEmpty) {
          visible[alert.key] = alert;
        }
      } catch (error) {
        debugPrint('Invalid alert: $error');
      }
    }

    _seenFrames.removeWhere((key, _) => !visible.containsKey(key));
    for (final key in visible.keys) {
      // FIX: clamp на int возвращает num — приводим к int.
      final next = ((_seenFrames[key] ?? 0) + 1).clamp(0, requiredFrames);
      _seenFrames[key] = next.toInt();
    }

    if (_pending != null && !visible.containsKey(_pending!.key)) {
      _pending = null;
    }

    _maybeCleanupLastSpoken();

    final now = DateTime.now();
    final eligible = <SafetyAlert>[];
    for (final alert in visible.values) {
      if ((_seenFrames[alert.key] ?? 0) < requiredFrames) continue;
      if (_current?.key == alert.key || _pending?.key == alert.key) continue;
      final previous = _lastSpoken[alert.key];
      if (previous != null && now.difference(previous) < _cooldownFor(alert)) {
        continue;
      }
      eligible.add(alert);
    }
    if (eligible.isEmpty) return;
    eligible.sort((a, b) => b.priority.compareTo(a.priority));
    final selected = eligible.first;
    if (_pending == null || selected.priority > _pending!.priority) {
      _pending = selected;
    }
    _ensureLoopRunning();
  }

  // FIX: единая точка запуска цикла. Гарантирует один активный loop.
  void _ensureLoopRunning() {
    if (_disposed || _manualSpeaking || !_enabled) return;
    if (_loopFuture != null) {
      _signalPending();
      return;
    }
    _loopFuture = _speakLoop().whenComplete(() {
      _loopFuture = null;
      // Если за время выхода появился новый pending — стартуем снова.
      if (_pending != null && !_disposed && !_manualSpeaking && _enabled) {
        _ensureLoopRunning();
      }
    });
    _signalPending();
  }

  void _signalPending() {
    final signal = _pendingSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
  }

  Future<void> _speakLoop() async {
    if (_disposed || _manualSpeaking) return;
    final generation = _generation;

    try {
      await initialize();
    } catch (error) {
      debugPrint('TTS loop init failed: $error');
      return;
    }

    while (_enabled &&
        !_disposed &&
        !_manualSpeaking &&
        generation == _generation) {
      final alert = _pending;
      _pending = null;

      if (alert == null) {
        // FIX: ждём сигнала вместо холостого выхода и повторного запуска.
        final signal = _pendingSignal = Completer<void>();
        try {
          await signal.future;
        } finally {
          if (identical(_pendingSignal, signal)) _pendingSignal = null;
        }
        continue;
      }

      final now = DateTime.now();
      final previous = _lastSpoken[alert.key];
      if (previous != null && now.difference(previous) < _cooldownFor(alert)) {
        continue;
      }

      _current = alert;
      debugPrint('TTS WARNING: ${alert.text}');
      try {
        final result = await _tts.speak(alert.text);
        if (result == 1) {
          // FIX: фиксируем время после успешного завершения речи,
          // чтобы кулдаун отсчитывался от конца, а не от начала.
          _lastSpoken[alert.key] = DateTime.now();
        } else {
          _lastSpoken.remove(alert.key);
        }
      } catch (error) {
        debugPrint('TTS warning failed: $error');
        _lastSpoken.remove(alert.key);
      } finally {
        if (generation == _generation) _current = null;
      }
    }
  }

  void _maybeCleanupLastSpoken() {
    final now = DateTime.now();
    if (now.difference(_lastCleanup) < _lastSpokenCleanupInterval) return;
    _lastCleanup = now;
    _lastSpoken.removeWhere((_, time) => now.difference(time) > _lastSpokenTtl);
  }

  /// Speak a reply to a voice command, without automatic warnings cutting in.
  Future<void> speakMessage(String text) async {
    if (_disposed || text.trim().isEmpty) return;
    await stop();
    if (_disposed) return;
    _manualSpeaking = true;
    final generation = _generation;
    try {
      await initialize();
      if (_disposed || generation != _generation) return;
      debugPrint('TTS COMMAND: $text');
      await _tts.speak(text);
    } catch (error) {
      debugPrint('TTS command failed: $error');
    } finally {
      if (generation == _generation) {
        _manualSpeaking = false;
        // FIX: если во время ручной речи накопился pending — запускаем loop.
        if (_pending != null && _enabled && !_disposed) {
          _ensureLoopRunning();
        }
      }
    }
  }

  // FIX: stop() больше не сбрасывает _busy/_loopFuture вручную —
  // loop сам корректно завершится. Используем единый completer для сериализации.
  Future<void> stop() async {
    _generation++;
    _current = null;
    _pending = null;
    _manualSpeaking = false;
    _seenFrames.clear();
    _signalPending();

    final previous = _stopCompleter;
    final completer = Completer<void>();
    _stopCompleter = completer;

    try {
      if (previous != null && !previous.isCompleted) {
        await previous.future;
      }
      await _tts.stop();
    } catch (error) {
      debugPrint('TTS stop error: $error');
    } finally {
      completer.complete();
      if (identical(_stopCompleter, completer)) _stopCompleter = null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _enabled = false;
    // FIX: дожидаемся активного loop, чтобы не оставить висящий speak.
    final loop = _loopFuture;
    await stop();
    if (loop != null) {
      try {
        await loop;
      } catch (_) {}
    }
  }
}
