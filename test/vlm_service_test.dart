import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yolo_live_detection/services/vlm_service.dart';

class FakeVlmBackend implements VlmBackend {
  int calls = 0, cancels = 0;
  Completer<Map<String, dynamic>>? gate;
  String? lastId;
  VlmFrame? lastFrame;
  @override
  Future<Map<String, dynamic>> describe(
    VlmFrame frame,
    String requestId,
    Future<void> abort,
  ) async {
    calls++;
    lastId = requestId;
    lastFrame = frame;
    return gate == null ? response() : gate!.future;
  }

  Map<String, dynamic> response() => {
    'request_id': lastId,
    'status': 'success',
    'description': 'На снимке слева виден стул.',
    'captured_at': lastFrame!.capturedAt.toUtc().toIso8601String(),
  };
  @override
  Future<void> cancel(String requestId) async {
    cancels++;
  }

  @override
  void dispose() {}
}

void main() {
  late FakeVlmBackend backend;
  late VlmService service;
  late DateTime now;
  late List<String> spoken;
  late List<Object> cancelled;
  late VlmFrame frame;
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  setUp(() {
    now = DateTime.utc(2026, 11, 21);
    frame = VlmFrame(Uint8List.fromList([255, 216, 255, 217]), now);
    backend = FakeVlmBackend();
    spoken = [];
    cancelled = [];
    service = VlmService(
      backend: backend,
      capture: () async => frame,
      clock: () => now,
      speak: (text, owner, isCurrent) async {
        if (isCurrent()) spoken.add(text);
      },
      cancelSpeech: cancelled.add,
    );
  });
  tearDown(() => service.dispose());

  test('one user request captures once, correlates and speaks historical description', () async {
    expect(await service.describe(), 'На снимке слева виден стул.');
    expect(backend.calls, 1);
    expect(spoken, ['На снимке слева виден стул.']);
    expect(service.lastMeasurement?['jpeg_bytes'], 4);
    expect(service.state, VlmState.idle);
  });
  test('repeated taps do not send multiple requests', () async {
    backend.gate = Completer();
    final first = service.describe();
    expect(await service.describe(), null);
    await settle();
    expect(backend.calls, 1);
    backend.gate!.complete(backend.response());
    await first;
  });
  test(
    'cancel invalidates immediately; late HTTP response cannot speak',
    () async {
      backend.gate = Completer();
      final pending = service.describe();
      await settle();
      service.cancel();
      expect(await pending, null);
      backend.gate!.complete(backend.response());
      await settle();
      expect(spoken, isEmpty);
      expect(cancelled, hasLength(1));
      expect(service.state, VlmState.cancelled);
      backend.gate = null;
      expect(await service.describe(), isNotNull);
    },
  );
  test(
    'closing camera or disposing during capture cannot upload a late frame',
    () async {
      final captureGate = Completer<VlmFrame>();
      final other = VlmService(
        backend: backend,
        capture: () => captureGate.future,
        speak: (text, owner, isCurrent) async {
          if (isCurrent()) spoken.add(text);
        },
        cancelSpeech: cancelled.add,
      );
      final pending = other.describe();
      other.dispose();
      expect(await pending, null);
      captureGate.complete(frame);
      await settle();
      expect(backend.calls, 0);
      expect(spoken, isEmpty);
    },
  );
  test(
    'old frame is rejected before network; local detector has no dependency',
    () async {
      now = now.add(const Duration(seconds: 2));
      expect(await service.describe(), null);
      expect(backend.calls, 0);
      expect(spoken.single, 'Подробное описание сейчас недоступно');
    },
  );
  test(
    'slow inference does not apply safety evidence TTL to the snapshot',
    () async {
      backend.gate = Completer();
      final pending = service.describe();
      await settle();
      now = now.add(const Duration(seconds: 30));
      backend.gate!.complete(backend.response());
      expect(await pending, isNotNull);
      expect(spoken.single, startsWith('На снимке'));
    },
  );
  test('incorrect request or capture identity is not narrated', () async {
    backend.gate = Completer();
    final pending = service.describe();
    await settle();
    backend.gate!.complete({...backend.response(), 'request_id': 'stale'});
    expect(await pending, null);
    expect(spoken.single, 'Подробное описание сейчас недоступно');
  });
  test('timeout aborts transport and reports unavailable', () async {
    backend.gate = Completer();
    final other = VlmService(
      backend: backend,
      capture: () async => frame,
      clock: () => now,
      timeout: const Duration(milliseconds: 5),
      speak: (text, owner, isCurrent) async {
        if (isCurrent()) spoken.add(text);
      },
      cancelSpeech: cancelled.add,
    );
    expect(await other.describe(), null);
    expect(backend.cancels, 1);
    expect(spoken.single, 'Подробное описание сейчас недоступно');
    other.dispose();
  });
  test('HTTP multipart sends actual JPEG and capture metadata', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/vlm/describe');
      expect(
        request.headers['content-type'],
        startsWith('multipart/form-data'),
      );
      final body = utf8.decode(request.bodyBytes, allowMalformed: true);
      expect(body, contains('content-type: image/jpeg'));
      expect(body, contains('frame.jpg'));
      expect(body, contains(frame.capturedAt.toIso8601String()));
      expect(body, contains('http-test'));
      return http.Response(jsonEncode({'status': 'success'}), 200);
    });
    final httpBackend = HttpVlmBackend(
      Uri.parse('http://localhost:8000'),
      client: client,
    );
    expect(
      (await httpBackend.describe(
        frame,
        'http-test',
        Completer<void>().future,
      ))['status'],
      'success',
    );
    httpBackend.dispose();
  });
}
