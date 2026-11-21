import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'services/safety_service.dart';
export 'services/safety_service.dart' show SafetyAlert, SafetyService;

class _Speech {
  _Speech(
    this.text,
    this.createdAt, {
    this.alert,
    this.remember = true,
    this.owner,
    this.isCurrent,
  });
  final Object? owner;
  final bool Function()? isCurrent;
  final bool remember;
  final String text;
  final DateTime createdAt;
  final SafetyAlert? alert;
  final done = Completer<void>();
  final cancelled = Completer<void>();
  int get priority => alert?.priority ?? 0;
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

/// One engine and one serialized speaker for warnings and voice/VLM replies.
/// Queue bounds: one active utterance, latest scene alerts, one manual reply.
class SafetyTtsService {
  SafetyTtsService({FlutterTts? tts, DateTime Function()? clock})
    : _tts = tts ?? FlutterTts(),
      _clock = clock ?? DateTime.now,
      _safety = SafetyService(clock: clock);

  final FlutterTts _tts;
  final DateTime Function() _clock;
  final SafetyService _safety;
  final Map<String, DateTime> _lastSpoken = {};
  List<SafetyAlert> _visible = const [];
  Future<void>? _initialization, _runner, _stopping;
  _Speech? _active, _message;
  DateTime? _activeEvidenceAt;
  Timer? _expiry;
  DateTime? _retryAfter;
  bool _enabled = true, _disposed = false, _audioBlocked = false;
  int _frames = 0;
  Future<void> Function(bool speaking)? onSpeakingChanged;
  bool Function(int priority)? deferAlert;
  double? lastResponseMs, lastObstacleToSpeechMs;
  void Function(double responseMs, double? obstacleMs)? onSpeechStarted;
  DateTime? _speakRequestedAt;
  final Map<String, DateTime> _confirmedAt = {};
  final Map<String, DateTime> _failedUntil = {};

  static const alertMaxAge = Duration(milliseconds: 1500);
  static const messageMaxAge = Duration(seconds: 4);
  String describeScene() => _safety.describeScene();

  bool get enabled => _enabled;
  bool get isSpeaking => _active != null;
  String get currentText => _active?.text ?? '';
  String lastSpokenText = '';
  bool offlineVoiceReady = false;
  String? lastError;
  double lastSafetyMs = 0;

  Future<void> initialize() {
    if (_disposed) return Future.error(StateError('TTS disposed'));
    return _initialization ??= _setup().onError((
      Object error,
      StackTrace stack,
    ) {
      _initialization = null;
      offlineVoiceReady = false;
      lastError = error.toString();
      _retryAfter = _clock().add(const Duration(seconds: 10));
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _setup() async {
    _tts.setErrorHandler((message) {
      lastError = message;
      offlineVoiceReady = false;
      debugPrint('TTS ENGINE ERROR: $message');
    });
    _tts.setStartHandler(() {
      final active = _active;
      if (active == null || active.cancelled.isCompleted) return;
      final now = _clock();
      final repeat = _lastSpoken.containsKey(active.alert?.cooldownKey);
      // Only native-started speech is eligible for the repeat command.
      if (active.remember) lastSpokenText = active.text;
      final requested = _speakRequestedAt;
      if (requested != null) {
        lastResponseMs = now.difference(requested).inMicroseconds / 1000;
      }
      lastObstacleToSpeechMs = null;
      final key = active.alert?.key;
      if (key != null) {
        _lastSpoken[active.alert!.cooldownKey] = now;
        final confirmed = _confirmedAt[key];
        if (confirmed != null) {
          lastObstacleToSpeechMs =
              now.difference(confirmed).inMicroseconds / 1000;
        }
      }
      final alert = active.alert;
      if (alert != null &&
          alert.confirmedAt != null &&
          alert.firstResultAt != null &&
          alert.firstCameraAt != null) {
        // Engine start callback, not an acoustic measurement or physical onset.
        debugPrint(
          'SAFETY LATENCY key=${alert.key} repeat=$repeat '
          'result_to_confirmation_ms=${alert.confirmedAt!.difference(alert.firstResultAt!).inMicroseconds / 1000} '
          'confirmation_to_tts_ms=${now.difference(alert.confirmedAt!).inMicroseconds / 1000} '
          'camera_to_tts_ms=${now.difference(alert.firstCameraAt!).inMicroseconds / 1000} '
          'evidence_age_at_tts_ms=${now.difference(alert.observedAt).inMicroseconds / 1000}',
        );
      }
      if (lastResponseMs != null) {
        onSpeechStarted?.call(lastResponseMs!, lastObstacleToSpeechMs);
      }
    });
    final language = await _tts.setLanguage('ru-RU');
    if (language is num && language < 0) {
      throw StateError('Russian TTS language data unavailable');
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      final voices = await _tts.getVoices;
      Map<String, String>? selected;
      if (voices is List) {
        for (final voice in voices) {
          if (voice is! Map) continue;
          final locale = voice['locale']?.toString() ?? '';
          final network = voice['network_required'];
          final features = voice['features']?.toString().toLowerCase() ?? '';
          if (locale.toLowerCase().replaceAll('_', '-').startsWith('ru-') &&
              (network == '0' || network == 0 || network == false) &&
              !features.contains('notinstalled') &&
              voice['name'] is String) {
            selected = {'name': voice['name'] as String, 'locale': locale};
            break;
          }
        }
      }
      if (selected == null) {
        throw StateError(
          'Install an offline Russian voice in Android TTS settings',
        );
      }
      final result = await _tts.setVoice(selected);
      if (result != 1) {
        throw StateError('Cannot select offline Russian TTS voice');
      }
      await _tts.setQueueMode(0);
      await _tts.setAudioAttributesForNavigation();
      debugPrint(
        'TTS OFFLINE voice=${selected['name']} network_required=false',
      );
    }
    await _tts.setSpeechRate(0.50);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
    offlineVoiceReady = true;
    lastError = null;
    _retryAfter = null;
    debugPrint('Safety TTS initialized: single speaker');
  }

  /// Called once per accepted result. No TTS future is awaited by the camera.
  List<SafetyAlert> onDetections({
    required Iterable<dynamic> detections,
    required int imageWidth,
    required int imageHeight,
    bool allowReliableDepth = false,
    double frameAgeMs = 0,
  }) {
    final watch = Stopwatch()..start();
    final alerts = _safety.evaluate(
      detections: detections,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      allowReliableDepth: allowReliableDepth,
      frameAgeMs: frameAgeMs,
    );
    onFrame(alerts);
    lastSafetyMs = watch.elapsedMicroseconds / 1000;
    if (++_frames <= 3 || _frames % 30 == 0) {
      debugPrint(
        'SAFETY PERF safety_ms=${lastSafetyMs.toStringAsFixed(3)} '
        'confirmed=${alerts.length} speaking=$isSpeaking',
      );
    }
    return alerts;
  }

  /// Input must be temporally confirmed observations, not raw server text.
  void onFrame(List<SafetyAlert> alerts) {
    if (_disposed || !_enabled) return;
    final now = _clock();
    _visible = alerts
        .where(
          (a) =>
              a.priority >= 1 &&
              a.priority <= 3 &&
              a.key.isNotEmpty &&
              a.text.isNotEmpty &&
              _fresh(a, now),
        )
        .take(3)
        .toList();
    _lastSpoken.removeWhere(
      (_, time) => now.difference(time) > const Duration(minutes: 5),
    );
    final keys = _visible.map((a) => a.key).toSet();
    _confirmedAt.removeWhere((key, _) => !keys.contains(key));
    for (final key in keys) {
      _confirmedAt.putIfAbsent(key, () => now);
    }
    _failedUntil.removeWhere((_, until) => !now.isBefore(until));
    final active = _active;
    final candidate = _pickAlert();
    if (active?.alert != null) {
      for (final alert in _visible) {
        if (alert.key == active!.alert!.key) {
          _activeEvidenceAt = alert.observedAt;
        }
      }
    }
    // A single missed detection must not chop a short phrase in half. The
    // active observation still expires; waiting warnings disappear immediately.
    if (active != null &&
        candidate != null &&
        candidate.priority >= 2 &&
        candidate.priority > active.priority) {
      active.cancel();
    }
    _scheduleExpiry();
    _kick();
  }

  bool _fresh(SafetyAlert alert, DateTime now) {
    final age = now.difference(alert.observedAt);
    return !age.isNegative && age < alertMaxAge;
  }

  static Duration cooldownFor(int priority) => Duration(
    seconds: priority >= 3
        ? 12
        : priority == 2
        ? 20
        : 30,
  );

  SafetyAlert? _pickAlert() {
    final now = _clock();
    SafetyAlert? best;
    for (final alert in _visible) {
      if (deferAlert?.call(alert.priority) == true) continue;
      final spoken = _lastSpoken[alert.cooldownKey];
      if (!_fresh(alert, now) ||
          _active?.alert?.key == alert.key ||
          (_failedUntil[alert.key]?.isAfter(now) ?? false) ||
          (spoken != null &&
              now.difference(spoken) < cooldownFor(alert.priority))) {
        continue;
      }
      if (best == null ||
          alert.priority > best.priority ||
          (alert.priority == best.priority &&
              (alert.riskScore > best.riskScore ||
                  (alert.riskScore == best.riskScore &&
                      alert.confidence > best.confidence)))) {
        best = alert;
      }
    }
    return best;
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    _expiry = null;
    if (_disposed) return;
    final deadlines = [
      for (final alert in _visible) alert.observedAt.add(alertMaxAge),
      if (_activeEvidenceAt != null && _active?.cancelled.isCompleted == false)
        _activeEvidenceAt!.add(alertMaxAge),
      if (_message != null) _message!.createdAt.add(messageMaxAge),
    ];
    if (deadlines.isEmpty) return;
    deadlines.sort();
    final delay = deadlines.first.difference(_clock());
    _expiry = Timer(delay.isNegative ? Duration.zero : delay, () {
      final now = _clock();
      _visible = _visible.where((a) => _fresh(a, now)).toList();
      if (_activeEvidenceAt != null &&
          now.difference(_activeEvidenceAt!) >= alertMaxAge) {
        _active!.cancel();
      }
      final message = _message;
      if (message != null &&
          now.difference(message.createdAt) >= messageMaxAge) {
        message.finish();
        _message = null;
      }
      _scheduleExpiry();
      _kick();
    });
  }

  void _kick() {
    if (_disposed ||
        _audioBlocked ||
        _runner != null ||
        (_retryAfter != null && _clock().isBefore(_retryAfter!))) {
      return;
    }
    if ((_message == null) && (!_enabled || _pickAlert() == null)) return;
    _runner = _run().whenComplete(() {
      _runner = null;
      _kick();
    });
  }

  Future<void> _run() async {
    try {
      await initialize();
      await _stopping;
      while (!_disposed && !_audioBlocked) {
        // Re-read the latest scene after initialization/stop, never an old job.
        final alert = _enabled ? _pickAlert() : null;
        final pendingMessage = _message;
        _Speech? job;
        if (alert != null && (alert.priority >= 2 || pendingMessage == null)) {
          job = _Speech(alert.text, _clock(), alert: alert);
        } else if (pendingMessage != null) {
          _message = null;
          if (_clock().difference(pendingMessage.createdAt) >= messageMaxAge ||
              pendingMessage.isCurrent?.call() == false) {
            pendingMessage.finish();
            continue;
          }
          job = pendingMessage;
        }
        if (job == null) break;
        _active = job;
        _activeEvidenceAt = job.alert?.observedAt;
        _scheduleExpiry();

        debugPrint(
          'TTS ${job.alert == null ? 'COMMAND' : 'WARNING'} '
          'priority=${job.priority}: ${job.text}',
        );
        final watch = Stopwatch()..start();
        try {
          // Our cancellation also covers engines whose speak future never
          // resolves after stop. Native stop still precedes the next speak.
          await onSpeakingChanged?.call(true);
          if (_disposed ||
              job.cancelled.isCompleted ||
              job.isCurrent?.call() == false ||
              (job.alert != null &&
                  (!_fresh(job.alert!, _clock()) ||
                      !_visible.any((a) => a.key == job!.alert!.key)))) {
            await _stopNative();
            continue;
          }
          _speakRequestedAt = _clock();
          final result = await Future.any<dynamic>([
            _tts.speak(job.text),
            job.cancelled.future.then((_) => 0),
          ]).timeout(Duration(seconds: job.alert == null ? 30 : 8));
          if (job.cancelled.isCompleted) {
            await _stopNative();
          } else if (result == 1) {
            offlineVoiceReady = true;
            lastError = null;
            if (job.alert != null) {
              _lastSpoken[job.alert!.cooldownKey] = _clock();
            }
          } else {
            offlineVoiceReady = false;
            lastError = 'TTS did not complete speech';
            if (job.alert != null) {
              _lastSpoken.remove(job.alert!.cooldownKey);
              _failedUntil[job.alert!.key] = _clock().add(
                const Duration(seconds: 2),
              );
            }
            await _stopNative();
          }
        } catch (error) {
          lastError = error.toString();
          offlineVoiceReady = false;
          debugPrint('TTS speech failed: $error');
          if (job.alert != null) {
            _lastSpoken.remove(job.alert!.cooldownKey);
            _failedUntil[job.alert!.key] = _clock().add(
              const Duration(seconds: 2),
            );
          }
          await _stopNative();
        } finally {
          debugPrint(
            'TTS PERF priority=${job.priority} '
            'speech_ms=${watch.elapsedMilliseconds} cancelled=${job.cancelled.isCompleted}',
          );
          job.finish();
          _active = null;
          _activeEvidenceAt = null;
          _speakRequestedAt = null;
          await onSpeakingChanged?.call(false);
          _scheduleExpiry();
        }
      }
    } catch (error) {
      debugPrint('TTS unavailable: $error');
      _message?.finish();
      _message = null;
    }
  }

  /// Latest reply replaces any queued reply. Important warnings may interrupt.
  Future<void> speakMessage(
    String text, {
    bool remember = true,
    Object? owner,
    bool Function()? isCurrent,
  }) {
    if (_disposed || _audioBlocked || text.trim().isEmpty) {
      return Future.value();
    }
    _message?.finish();
    final job = _Speech(
      text,
      _clock(),
      remember: remember,
      owner: owner,
      isCurrent: isCurrent,
    );
    _message = job;
    if (_active?.alert == null) _active?.cancel();
    _scheduleExpiry();
    _kick();
    return job.done.future;
  }

  /// Cancel one manual producer without stopping an automatic safety warning.
  void cancelMessage(Object owner) {
    if (identical(_message?.owner, owner)) {
      _message?.finish();
      _message = null;
    }
    if (_active?.alert == null && identical(_active?.owner, owner)) {
      _active?.cancel();
    }
    _scheduleExpiry();
    _kick();
  }

  void setEnabled(bool value) {
    if (_disposed || _enabled == value) return;
    _enabled = value;
    _visible = const [];
    _safety.reset();
    _confirmedAt.clear();
    if (!value && _active?.alert != null) _active!.cancel();
    _scheduleExpiry();
    _kick();
  }

  /// Mode transitions clear evidence but retain the engine and cooldown.
  /// Manual replies survive an automatic mode change.
  void resetScene() {
    _visible = const [];
    _safety.reset();
    _confirmedAt.clear();
    if (_active?.alert != null) _active!.cancel();
    _scheduleExpiry();
  }

  Future<void> _stopNative() {
    return _stopping ??= _tts
        .stop()
        .timeout(const Duration(seconds: 2))
        .then<void>(
          (result) {
            if (result != 1) {
              _audioBlocked = true;
              offlineVoiceReady = false;
              lastError = 'TTS could not confirm stop';
              _message?.finish();
              _message = null;
            }
          },
          onError: (Object error, StackTrace stack) {
            // Never start another utterance if native stop cannot be confirmed.
            _audioBlocked = true;
            offlineVoiceReady = false;
            lastError = 'TTS stop failed: $error';
            _message?.finish();
            _message = null;
            debugPrint(lastError);
          },
        )
        .whenComplete(() {
          _stopping = null;
        });
  }

  Future<void> stop() {
    resetScene();
    _message?.finish();
    _message = null;
    _active?.cancel();
    _expiry?.cancel();
    _expiry = null;
    // No native speech has been submitted while initialization is pending.
    // Calling stop then can hang on Android's not-yet-connected TTS engine.
    if (_active == null) return _stopping ?? Future.value();
    return _stopNative();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _enabled = false;
    await stop();
    await _runner;
  }
}
