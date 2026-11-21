import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/safety_tts_service.dart';
import 'package:yolo_live_detection/services/vlm_service.dart';

import 'safety_tts_service_test.dart' show FakeTts;
import 'vlm_service_test.dart' show FakeVlmBackend;

import 'dart:typed_data';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));
  test('critical warning preempts VLM through one speaker; cancelling VLM preserves warning', () async {
    final native = FakeTts();
    final now = DateTime.now();
    final tts = SafetyTtsService(tts: native, clock: () => now);
    final backend = FakeVlmBackend();
    final vlm = VlmService(
      backend: backend,
      capture: () async => VlmFrame(Uint8List.fromList([255, 216]), now),
      clock: () => now,
      speak: (text, owner, isCurrent) =>
          tts.speakMessage(text, owner: owner, isCurrent: isCurrent),
      cancelSpeech: tts.cancelMessage,
    );
    final description = vlm.describe();
    await settle();
    expect(native.spoken.single, startsWith('На снимке'));
    tts.onFrame([
      SafetyAlert(
        key: 'stairs',
        text: 'Впереди лестница',
        priority: 3,
        observedAt: now,
      ),
    ]);
    await settle();
    expect(native.spoken.last, 'Впереди лестница');
    expect(native.maxActive, 1);
    final stops = native.stops;
    vlm.cancel();
    await settle();
    expect(
      native.stops,
      stops,
      reason: 'VLM cancellation must not stop an active critical warning',
    );
    native.complete();
    await description;
    vlm.dispose();
    await tts.dispose();
  });
  test('cancelled VLM queued behind a warning never starts after it', () async {
    final native = FakeTts();
    final now = DateTime.now();
    final tts = SafetyTtsService(tts: native, clock: () => now);
    tts.onFrame([
      SafetyAlert(
        key: 'stairs',
        text: 'Впереди лестница',
        priority: 3,
        observedAt: now,
      ),
    ]);
    await settle();
    final owner = Object();
    var current = true;
    final queued = tts.speakMessage(
      'На снимке видна дверь.',
      owner: owner,
      isCurrent: () => current,
    );
    current = false;
    tts.cancelMessage(owner);
    native.complete();
    await queued;
    await settle();
    expect(native.spoken, ['Впереди лестница']);
    await tts.dispose();
  });
  test(
    'valid snapshot older than 1500ms is a manual reply, not safety evidence',
    () async {
      final native = FakeTts();
      final tts = SafetyTtsService(tts: native);
      final owner = Object();
      final result = tts.speakMessage(
        'На момент съёмки в комнате был стул.',
        owner: owner,
        isCurrent: () => true,
      );
      await settle();
      expect(native.spoken.single, startsWith('На момент съёмки'));
      native.complete();
      await result;
      await tts.dispose();
    },
  );
}
