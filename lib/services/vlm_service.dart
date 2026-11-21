import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

enum VlmState { idle, capturing, processing, speaking, cancelled, error }

class VlmFrame {
  const VlmFrame(this.jpeg, this.capturedAt, {this.preprocessingMs = 0});
  final Uint8List jpeg;
  final DateTime capturedAt;
  final double preprocessingMs;
}

abstract interface class VlmBackend {
  Future<Map<String, dynamic>> describe(
    VlmFrame frame,
    String requestId,
    Future<void> abort,
  );
  Future<void> cancel(String requestId);
  void dispose();
}

class HttpVlmBackend implements VlmBackend {
  HttpVlmBackend(Uri baseUrl, {http.Client? client})
    : this.configured(() => baseUrl, client: client);
  HttpVlmBackend.configured(this._resolveBaseUrl, {http.Client? client})
    : _client = client ?? http.Client();
  final Uri Function() _resolveBaseUrl;
  Uri get baseUrl => _resolveBaseUrl();
  final http.Client _client;
  @override
  Future<Map<String, dynamic>> describe(
    VlmFrame frame,
    String requestId,
    Future<void> abort,
  ) async {
    final request =
        http.AbortableMultipartRequest(
            'POST',
            baseUrl.resolve('/vlm/describe'),
            abortTrigger: abort,
          )
          ..fields.addAll({
            'request_id': requestId,
            'question':
                'Опиши видимое окружение на русском языке в 2–4 предложениях.',
            'captured_at': frame.capturedAt.toUtc().toIso8601String(),
          })
          ..files.add(
            http.MultipartFile.fromBytes(
              'image',
              frame.jpeg,
              filename: 'frame.jpg',
              contentType: MediaType('image', 'jpeg'),
            ),
          );
    final response = await _client.send(request);
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > 16384) {
        throw const FormatException('Oversized VLM response');
      }
    }
    if (response.statusCode != 200) {
      throw StateError('VLM HTTP ${response.statusCode}');
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  @override
  Future<void> cancel(String requestId) async {
    try {
      await _client
          .delete(baseUrl.resolve('/vlm/requests/$requestId'))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Cancellation remains local even when the LAN is lost. */
    }
  }

  @override
  void dispose() => _client.close();
}

class VlmService {
  VlmService({
    required this.backend,
    required this.capture,
    required this.speak,
    required this.cancelSpeech,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 50),
  }) : _clock = clock ?? DateTime.now;
  final VlmBackend backend;
  final Future<VlmFrame> Function() capture;
  final Future<void> Function(
    String text,
    Object owner,
    bool Function() isCurrent,
  )
  speak;
  final void Function(Object owner) cancelSpeech;
  final DateTime Function() _clock;
  final Duration timeout;
  VlmState state = VlmState.idle;
  String statusText = '', description = '';
  Map<String, dynamic>? lastMeasurement;
  void Function()? onChanged;
  int _epoch = 0;
  bool _disposed = false;
  Completer<void>? _abort;
  String? _requestId;
  Object? _speechOwner;
  bool get isBusy =>
      state == VlmState.capturing ||
      state == VlmState.processing ||
      state == VlmState.speaking;
  void _state(VlmState value, String message) {
    state = value;
    statusText = message;
    onChanged?.call();
  }

  Future<String?> describe() async {
    if (_disposed || isBusy) return null;
    final epoch = ++_epoch;
    bool current() => !_disposed && epoch == _epoch;
    final abort = Completer<void>();
    _abort = abort;
    final owner = Object();
    _speechOwner = owner;
    final id = 'vlm-${_clock().microsecondsSinceEpoch}-$epoch';
    _requestId = id;
    description = '';
    lastMeasurement = null;
    final watch = Stopwatch()..start();
    try {
      _state(VlmState.capturing, 'Анализирую изображение');
      final frame = await Future.any<VlmFrame?>([
        capture().timeout(const Duration(seconds: 3)),
        abort.future.then((_) => null),
      ]);
      if (!current() || frame == null) return null;
      final age = _clock().difference(frame.capturedAt);
      if (age.isNegative ||
          age > const Duration(milliseconds: 1500) ||
          frame.jpeg.isEmpty ||
          frame.jpeg.length > 768 * 1024) {
        throw StateError('No fresh camera frame');
      }
      _state(VlmState.processing, 'Анализирую изображение');
      final httpWatch = Stopwatch()..start();
      final result = await Future.any<Map<String, dynamic>?>([
        backend.describe(frame, id, abort.future),
        abort.future.then((_) => null),
      ]).timeout(timeout);
      if (!current() || result == null) return null;
      final text = (result['description'] as String?)?.trim() ?? '';
      if (result['request_id'] != id ||
          result['status'] != 'success' ||
          DateTime.tryParse(result['captured_at'] as String? ?? '')?.toUtc() !=
              frame.capturedAt.toUtc() ||
          text.isEmpty ||
          text.length > 600 ||
          !RegExp(r'[а-яА-ЯёЁ]').hasMatch(text)) {
        throw const FormatException('Invalid or stale VLM result');
      }
      description =
          RegExp(
            r'^На (снимке|момент съ[её]мки)',
            caseSensitive: false,
          ).hasMatch(text)
          ? text
          : 'На снимке: $text';
      lastMeasurement = {
        ...result,
        'http_ms': httpWatch.elapsedMicroseconds / 1000,
        'capture_preprocessing_ms': frame.preprocessingMs,
        'jpeg_bytes': frame.jpeg.length,
        'full_response_ms': watch.elapsedMicroseconds / 1000,
      };
      _state(VlmState.speaking, description);
      await speak(description, owner, current);
      if (!current()) return null;
      _state(VlmState.idle, description);
      return description;
    } catch (_) {
      if (!current()) return null;
      if (!abort.isCompleted) abort.complete();
      unawaited(backend.cancel(id));
      const message = 'Подробное описание сейчас недоступно';
      _state(VlmState.error, message);
      await speak(message, owner, current);
      return null;
    } finally {
      if (current()) {
        _abort = null;
        _requestId = null;
        _speechOwner = null;
      }
    }
  }

  void cancel() {
    ++_epoch; // Invalidate before any asynchronous network/native cleanup.
    final id = _requestId;
    _requestId = null;
    final abort = _abort;
    _abort = null;
    if (abort != null && !abort.isCompleted) abort.complete();
    final owner = _speechOwner;
    _speechOwner = null;
    if (owner != null) cancelSpeech(owner);
    if (id != null) unawaited(backend.cancel(id));
    if (!_disposed && isBusy) _state(VlmState.cancelled, 'Описание отменено');
  }

  void dispose() {
    _disposed = true;
    cancel();
    backend.dispose();
  }
}
