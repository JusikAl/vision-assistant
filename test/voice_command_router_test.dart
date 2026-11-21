import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/voice_command_router.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

void main() {
  test('all grammar phrases route only as final whole phrases', () {
    var id = 0;
    final router = VoiceCommandRouter();
    for (final entry in VoiceCommandRouter.phrases.entries) {
      router.begin(++id);
      expect(
        router.route(entry.key, session: id, isFinal: false),
        VoiceCommand.unknown,
      );
      expect(
        router.route(
          '${entry.key.toUpperCase()}?!',
          session: id,
          isFinal: true,
        ),
        entry.value,
      );
      expect(
        router.route(entry.key, session: id, isFinal: true),
        VoiceCommand.unknown,
      );
    }
  });
  test('negative, mixed, repeated, unknown and long phrases rejected', () {
    final router = VoiceCommandRouter();
    var id = 0;
    for (final phrase in [
      'не начать',
      'Не начинай',
      'Не останавливай',
      'Как начать работу?',
      'Не надо начинать',
      'Это начало фильма',
      'не стоп',
      'начать начать',
      'начать закончить',
      'как начать',
      'я хочу опиши окружение пожалуйста',
      '[unk]',
      '[unk] начать',
      'погода сегодня',
      'что впереди потом начать',
      '',
      'опиши',
      'повтори',
    ]) {
      router.begin(++id);
      expect(
        router.route(phrase, session: id, isFinal: true),
        VoiceCommand.unknown,
        reason: phrase,
      );
    }
  });
  test('environment intent is separate from the existing scene analyzer', () {
    final router = VoiceCommandRouter()..begin(1);
    expect(
      router.route('Опиши окружение', session: 1, isFinal: true),
      VoiceCommand.describeEnvironment,
    );
    router.begin(2);
    expect(
      router.route('Что впереди?', session: 2, isFinal: true),
      VoiceCommand.describe,
    );
  });
  test('conflicting alternatives reject even a primary command', () {
    final router = VoiceCommandRouter();
    var id = 0;
    for (final alternatives in [
      ['не начинай'],
      ['как начать работу'],
      ['закончить'],
      ['начать', '[unk]'],
      [''],
    ]) {
      router.begin(++id);
      expect(
        router.route(
          'начать',
          session: id,
          isFinal: true,
          alternatives: alternatives,
        ),
        VoiceCommand.unknown,
      );
    }
    router.begin(++id);
    expect(
      router.route(
        'начать',
        session: id,
        isFinal: true,
        alternatives: ['начни', 'начать'],
      ),
      VoiceCommand.start,
    );
    router.begin(++id);
    expect(
      router.route(
        '[unk]',
        session: id,
        isFinal: true,
        alternatives: ['начать'],
      ),
      VoiceCommand.unknown,
    );
  });
  test('cancelled and stale sessions cannot route', () {
    final router = VoiceCommandRouter()
      ..begin(1)
      ..begin(2);
    expect(
      router.route('начать', session: 1, isFinal: true),
      VoiceCommand.unknown,
    );
    router.cancel();
    expect(
      router.route('начать', session: 2, isFinal: true),
      VoiceCommand.unknown,
    );
  });
}
