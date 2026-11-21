import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/voice_command_handler.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

void main() {
  test(
    'four commands route exactly; repeat labels history and unknown never acts',
    () async {
      var starts = 0, stops = 0, describes = 0;
      final handler = VoiceCommandHandler(
        start: () async {
          starts++;
          return true;
        },
        stop: () async {
          stops++;
        },
        scene: LocalSceneDescription(() {
          describes++;
          return 'Слева стул';
        }),
        previousMessage: () => 'Впереди человек',
        setWarnings: (_) {},
      );
      for (final text in ['Начать!', 'Начни', 'Запусти']) {
        await handler.handle(text);
      }
      for (final text in ['Остановить.', 'Стоп', 'Останови']) {
        await handler.handle(text);
      }
      for (final text in ['Что впереди?', 'Что передо мной']) {
        expect(await handler.handle(text), 'Слева стул');
      }
      expect(
        await handler.handle('ПОВТОРИ!'),
        startsWith('Повтор предыдущего сообщения:'),
      );
      for (final text in [
        'не начать',
        'как остановить',
        'повтори и останови',
        'опиши как начать',
        'не выключи предупреждения',
      ]) {
        expect(await handler.handle(text), 'Команда не распознана');
        expect(VoiceCommandParser.parse(text), VoiceCommand.unknown);
      }
      expect([starts, stops, describes], [3, 3, 2]);
      expect(
        await handler.handleCommand(VoiceCommand.describeEnvironment),
        'Описание окружения пока недоступно',
      );
      expect([starts, stops, describes], [3, 3, 2]);
    },
  );
  test('description failure does not block other commands', () async {
    final handler = VoiceCommandHandler(
      start: () async => true,
      stop: () async {},
      scene: LocalSceneDescription(() => throw StateError('offline')),
      previousMessage: () => '',
      setWarnings: (_) {},
    );
    expect(
      await handler.handle('что впереди'),
      'Актуальное описание недоступно',
    );
    expect(await handler.handle('повтори'), 'Пока нечего повторять');
    expect(await handler.handle('начать'), 'Обнаружение запущено');
  });
}
