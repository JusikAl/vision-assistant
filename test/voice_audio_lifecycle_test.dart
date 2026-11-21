import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/safety_tts_service.dart';
import 'package:yolo_live_detection/services/vosk_service.dart';
import 'package:yolo_live_detection/services/voice_command_router.dart';
import 'package:yolo_live_detection/services/voice_command_handler.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

import 'vosk_service_test.dart' show FakeVoskBackend;
import 'safety_tts_service_test.dart' show FakeTts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'critical warning waits for microphone release and invalidates final',
    () async {
      final backend = FakeVoskBackend();
      final voice = VoskService(backend: backend);
      final nativeTts = FakeTts();
      final now = DateTime(2026);
      final tts = SafetyTtsService(tts: nativeTts, clock: () => now);
      final router = VoiceCommandRouter();
      tts.onSpeakingChanged = (speaking) async {
        if (speaking) router.cancel();
        await voice.setSpeaking(speaking);
      };
      final pending = voice.startListening();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final old = voice.session;
      router.begin(old);
      backend.cancelGate = Completer<void>();
      tts.onFrame([
        SafetyAlert(
          key: 'stairs:track:1',
          text: 'Впереди лестница',
          priority: 3,
          observedAt: now,
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await pending, null);
      expect(nativeTts.spoken, isEmpty);
      backend.emit(old, 'final');
      expect(
        router.route('начать', session: old, isFinal: true),
        VoiceCommand.unknown,
      );
      backend.cancelGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(nativeTts.spoken, ['Впереди лестница']);
      nativeTts.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await voice.dispose();
      await tts.dispose();
      await backend.controller.close();
    },
  );

  test('stop detection action leaves voice reusable for next Start', () async {
    var running = true;
    final backend = FakeVoskBackend();
    final voice = VoskService(backend: backend);
    final router = VoiceCommandRouter();
    final handler = VoiceCommandHandler(
      start: () async {
        running = true;
        return true;
      },
      stop: () async {
        running = false;
      },
      scene: LocalSceneDescription(() => 'Нет свежих данных с камеры'),
      previousMessage: () => '',
      setWarnings: (_) {},
    );
    for (final phrase in ['закончить', 'начать']) {
      final pending = voice.startListening();
      final id = voice.session;
      router.begin(id);
      await Future<void>.delayed(Duration.zero);
      backend.emit(id, 'final', text: phrase);
      final text = await pending;
      expect(voice.beginExecution(id), true);
      await handler.handleCommand(
        router.route(text!, session: id, isFinal: true),
      );
      voice.endExecution(id);
      expect(running, phrase == 'начать');
    }
    expect(backend.loads, 1);
    expect(backend.closes, 0);
    await voice.dispose();
    await backend.controller.close();
  });
}
