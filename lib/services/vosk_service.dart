import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Native AudioRecord is the only microphone owner. No record/STT fallback.
enum VoskState {
  uninitialized,
  loadingModel,
  ready,
  listening,
  processing,
  commandExecution,
  cancelled,
  error,
  disposed,
}

abstract interface class VoskBackend {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> initialize();
  Future<void> start(int session);
  Future<void> stop();
  Future<void> cancel();
  Future<void> dispose();
}

class NativeVoskBackend implements VoskBackend {
  static const channel = MethodChannel('navigation/vosk');
  static const eventChannel = EventChannel('navigation/vosk/events');
  @override
  Stream<Map<String, dynamic>> get events => eventChannel
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));
  @override
  Future<Map<String, dynamic>> initialize() async => Map<String, dynamic>.from(
    await channel.invokeMethod('initialize') as Map,
  );
  @override
  Future<void> start(int session) => channel.invokeMethod('start', {
    'session': session,
    'diagnostic_capture': const bool.fromEnvironment(
      'VOSK_DIAGNOSTICS_ENABLED',
    ),
  });
  @override
  Future<void> stop() => channel.invokeMethod('stop');
  @override
  Future<void> cancel() => channel.invokeMethod('cancel');
  @override
  Future<void> dispose() => channel.invokeMethod('dispose');
}

class VoskService {
  VoskService({VoskBackend? backend})
    : _backend = backend ?? NativeVoskBackend() {
    _subscription = _backend.events.listen(
      _event,
      onError: (Object error) => _fail(error),
    );
  }
  final VoskBackend _backend;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  Future<void>? _initialization;
  Future<void> _cleanup = Future.value();
  Completer<String?>? _result;
  Timer? _watchdog;
  int _session = 0;
  bool _disposed = false, _speaking = false;
  VoskState state = VoskState.uninitialized;
  void Function(VoskState)? onStateChanged;
  void Function(String)? onPartial;
  void Function(Map<String, dynamic>)? onMeasured;
  double? loadMs;
  Map<String, dynamic>? lastMeasurement;
  String rawText = '';
  List<String> alternatives = const [];
  String? lastError;
  bool get isSpeaking => _speaking;
  bool get isListening => state == VoskState.listening;
  bool get isProcessing =>
      state == VoskState.loadingModel || state == VoskState.processing;
  int get session => _session;
  bool isCurrent(int id) => !_disposed && !_speaking && id == _session;

  void _state(VoskState value) {
    state = value;
    onStateChanged?.call(value);
  }

  Future<void> initialize() {
    if (_disposed) return Future.error(StateError('Vosk disposed'));
    return _initialization ??= _load();
  }

  Future<void> _load() async {
    _state(VoskState.loadingModel);
    try {
      final metrics = await _backend.initialize();
      loadMs = (metrics['load_ms'] as num).toDouble();
      debugPrint('VOSK LOAD ${jsonEncode(metrics)}');
      if (!_disposed && state == VoskState.loadingModel) {
        _state(VoskState.ready);
      }
    } catch (error) {
      _initialization = null;
      if (!_disposed) _state(VoskState.error);
      rethrow;
    }
  }

  Future<String?> startListening() {
    if (_disposed ||
        _speaking ||
        _result != null ||
        state == VoskState.commandExecution) {
      return Future.value(null);
    }
    final result = Completer<String?>();
    _result = result;
    final id = ++_session;
    rawText = '';
    alternatives = const [];
    lastMeasurement = null;
    lastError = null;
    unawaited(_begin(id));
    return result.future;
  }

  Future<void> _begin(int id) async {
    try {
      await _cleanup;
      if (!isCurrent(id)) return;
      await initialize();
      if (!isCurrent(id)) return;
      _state(VoskState.processing);
      await _backend.start(id);
      if (!isCurrent(id) || _result == null) return;
      // Native listener event can arrive before the method acknowledgement.
      if (state == VoskState.processing) _state(VoskState.listening);
      _watchdog = Timer(const Duration(seconds: 10), () {
        if (isCurrent(id)) {
          _fail(TimeoutException('Vosk audio session timeout'));
        }
      });
    } catch (error) {
      if (isCurrent(id)) _fail(error);
    }
  }

  void _event(Map<String, dynamic> event) {
    final id = event['session'];
    if (id is! int || !isCurrent(id) || _result == null) return;
    switch (event['type']) {
      case 'listening':
        _state(VoskState.listening);
      case 'processing':
        _state(VoskState.processing);
      case 'partial':
        final data = jsonDecode(event['raw'] as String) as Map;
        final text = data['partial'] as String? ?? '';
        debugPrint('VOSK PARTIAL session=$id text=$text');
        onPartial?.call(text); // Never route a partial.
      case 'final':
        try {
          final data = jsonDecode(event['raw'] as String) as Map;
          rawText = data['text'] as String? ?? '';
          // Keep the primary final text. Never promote a lower-ranked command.
          alternatives = List<String>.unmodifiable(
            (data['alternatives'] as List? ?? const []).map(
              (value) => (value as Map)['text'] as String,
            ),
          );
          lastMeasurement = Map<String, dynamic>.unmodifiable({
            ...event,
            'raw_text': rawText,
          });
          debugPrint('VOSK FINAL ${jsonEncode(lastMeasurement)}');
          onMeasured?.call(lastMeasurement!);
          _watchdog?.cancel();
          final result = _result;
          _result = null; // Consume before callbacks or duplicate events.
          _state(VoskState.ready);
          result?.complete(
            (event['voiced_frames'] as num? ?? 0) >= 8 && rawText.isNotEmpty
                ? rawText
                : null,
          );
        } catch (error) {
          _fail(error);
        }
      case 'error':
        _fail(StateError(event['message'].toString()));
    }
  }

  Future<void> stopListening() async {
    if (!isListening) return;
    _state(VoskState.processing);
    try {
      await _backend.stop();
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (_disposed) return;
    lastError = error.toString();
    debugPrint('VOSK ERROR $error');
    final result = _result;
    _result = null;
    ++_session;
    _watchdog?.cancel();
    _cleanup = _cleanup
        .then((_) => _backend.cancel())
        .catchError((Object _) {});
    _state(VoskState.error);
    result?.completeError(error);
  }

  Future<void> cancel() {
    ++_session; // Invalidate synchronously, before waiting for native cleanup.
    _watchdog?.cancel();
    final result = _result;
    _result = null;
    result?.complete(null);
    if (!_disposed) _state(VoskState.cancelled);
    return _cleanup = _cleanup.then((_) => _backend.cancel()).catchError((
      Object error,
    ) {
      lastError = error.toString();
      if (!_disposed) _state(VoskState.error);
    });
  }

  Future<void> setSpeaking(bool value) async {
    _speaking = value;
    if (value) await cancel();
    if (!_disposed && !value && state == VoskState.cancelled) {
      _state(VoskState.ready);
    }
  }

  bool beginExecution(int id) {
    if (!isCurrent(id) || state != VoskState.ready) return false;
    _state(VoskState.commandExecution);
    return true;
  }

  void endExecution(int id) {
    if (isCurrent(id) && state == VoskState.commandExecution) {
      _state(VoskState.ready);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await cancel();
    await _subscription.cancel();
    await _backend.dispose();
    _state(VoskState.disposed);
  }
}
