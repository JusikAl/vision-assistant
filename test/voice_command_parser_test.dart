import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/voice_command_parser.dart';

void main() {
  test(
    'whole repeated commands normalize, mixed and negated text never does',
    () {
      expect(
        VoiceCommandParser.parse('Остановить. Остановить.'),
        VoiceCommand.stop,
      );
      expect(
        VoiceCommandParser.parse('Что впереди? Что впереди?'),
        VoiceCommand.describe,
      );
      for (final text in [
        'не стоп не стоп',
        'стоп начни',
        'как начать как начать',
        'что впереди что',
        'остановить и начать',
        'повтори остановить повтори остановить',
      ]) {
        expect(VoiceCommandParser.parse(text), VoiceCommand.unknown);
      }
    },
  );
  test('all requested Russian aliases and punctuation', () {
    for (final text in [
      'Начать',
      'Запустить',
      'Включи камеру',
      'Начать детекцию',
    ]) {
      expect(VoiceCommandParser.parse(text), VoiceCommand.start);
    }
    for (final text in ['Стоп!', 'Остановить', 'Закончи', 'Выключи детекцию']) {
      expect(VoiceCommandParser.parse(text), VoiceCommand.stop);
    }
    for (final text in ['Что впереди?', 'Что рядом?', 'Что ты видишь?']) {
      expect(VoiceCommandParser.parse(text), VoiceCommand.describe);
    }
    expect(
      VoiceCommandParser.parse('Опиши окружение'),
      VoiceCommand.describeEnvironment,
    );
    expect(VoiceCommandParser.parse('опиши'), VoiceCommand.unknown);
    expect(
      VoiceCommandParser.parse('  НАЧАТЬ   ДЕТЕКЦИЮ. '),
      VoiceCommand.start,
    );
  });
  test('no accidental substring commands or negations', () {
    for (final text in [
      'не начать',
      'не включи камеру',
      'стопка',
      'как запустить',
      '',
    ]) {
      expect(VoiceCommandParser.parse(text), VoiceCommand.unknown);
    }
    expect(VoiceCommandParser.normalize('Ещё, раз!'), 'еще раз');
  });
}
