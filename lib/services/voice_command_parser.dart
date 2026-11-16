enum VoiceCommand { start, stop, describe, unknown }

/// Exact phrases avoid accidental substring commands and negated requests.
class VoiceCommandParser {
  static String normalize(String text) => text
      .toLowerCase()
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^а-яa-z0-9\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static VoiceCommand parse(String text) {
    final command = normalize(text)
        .replaceFirst(RegExp(r'^(?:пожалуйста|джарвис) '), '')
        .replaceFirst(RegExp(r' пожалуйста$'), '');
    if (const {
      'стоп',
      'остановить',
      'останови',
      'закончи',
      'заверши обнаружение',
      'выключи камеру',
      'выключи детекцию',
      'останови детекцию',
      'остановить обнаружение',
    }.contains(command)) {
      return VoiceCommand.stop;
    }
    if (const {
      'начать',
      'начни',
      'запусти',
      'запустить',
      'включи камеру',
      'начать детекцию',
      'начни детекцию',
      'начни обнаружение',
      'начать обнаружение',
      'запустить обнаружение',
      'запусти обнаружение',
      'включи детекцию',
    }.contains(command)) {
      return VoiceCommand.start;
    }
    if (const {
      'что впереди',
      'что рядом',
      'что вокруг',
      'опиши окружение',
      'что ты видишь',
      'что видишь',
      'опиши',
    }.contains(command)) {
      return VoiceCommand.describe;
    }
    if (command.startsWith('опиши ') &&
        !RegExp(r'(?:^|\s)(?:не|нет)(?:\s|$)').hasMatch(command)) {
      return VoiceCommand.describe;
    }
    return VoiceCommand.unknown;
  }
}
