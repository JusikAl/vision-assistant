import 'voice_command_parser.dart';

/// One final result per current PTT session. No substring or fuzzy matching.
class VoiceCommandRouter {
  int? _session, _consumed;
  void begin(int session) {
    _session = session;
    _consumed = null;
  }

  void cancel() {
    _session = null;
  }

  static const phrases = <String, VoiceCommand>{
    'начать': VoiceCommand.start,
    'начни': VoiceCommand.start,
    'запусти': VoiceCommand.start,
    'закончить': VoiceCommand.stop,
    'останови': VoiceCommand.stop,
    'стоп': VoiceCommand.stop,
    'что впереди': VoiceCommand.describe,
    'что передо мной': VoiceCommand.describe,
    'опиши окружение': VoiceCommand.describeEnvironment,
    'опиши обстановку': VoiceCommand.describeEnvironment,
    'что вокруг': VoiceCommand.describe,
  };

  VoiceCommand route(
    String raw, {
    required int session,
    required bool isFinal,
    Iterable<String> alternatives = const [],
  }) {
    if (!isFinal || session != _session || _consumed == session) {
      return VoiceCommand.unknown;
    }
    _consumed = session;
    final command = phrases[VoiceCommandParser.normalize(raw)];
    if (command == null ||
        alternatives.any(
          (text) => phrases[VoiceCommandParser.normalize(text)] != command,
        )) {
      return VoiceCommand.unknown;
    }
    return command;
  }
}
