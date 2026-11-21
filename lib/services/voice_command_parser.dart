enum VoiceCommand {
  start,
  stop,
  describe,
  describeEnvironment,
  repeat,
  enableWarnings,
  disableWarnings,
  help,
  unknown,
}

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
    // Whisper can repeat a complete phrase, e.g. "Остановить. Остановить."
    // Accept only an exact repetition covering EVERY token. Mixed requests,
    // negations and partial trailing phrases are never discarded or guessed.
    final words = command.split(' ');
    for (var size = 1; size <= words.length ~/ 2; size++) {
      if (words.length % size != 0) continue;
      var repeated = true;
      for (var i = size; i < words.length; i++) {
        if (words[i] != words[i % size]) {
          repeated = false;
          break;
        }
      }
      if (!repeated) continue;
      final intent = parse(words.take(size).join(' '));
      if (const {
        VoiceCommand.start,
        VoiceCommand.stop,
        VoiceCommand.describe,
        VoiceCommand.repeat,
      }.contains(intent)) {
        return intent;
      }
    }
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
    if (const {'опиши окружение', 'опиши обстановку'}.contains(command)) {
      return VoiceCommand.describeEnvironment;
    }
    if (const {
      'что впереди',
      'что передо мной',
      'что рядом',
      'что вокруг',
      'что ты видишь',
      'что видишь',
    }.contains(command)) {
      return VoiceCommand.describe;
    }
    if (const {
      'повтори',
      'повторить',
      'еще раз',
      'скажи снова',
    }.contains(command)) {
      return VoiceCommand.repeat;
    }
    if (const {
      'включи предупреждения',
      'включить предупреждения',
      'включи звук',
    }.contains(command)) {
      return VoiceCommand.enableWarnings;
    }
    if (const {
      'выключи предупреждения',
      'отключи предупреждения',
      'выключи звук',
    }.contains(command)) {
      return VoiceCommand.disableWarnings;
    }
    if (const {'помощь', 'команды', 'подсказка'}.contains(command)) {
      return VoiceCommand.help;
    }
    return VoiceCommand.unknown;
  }
}
