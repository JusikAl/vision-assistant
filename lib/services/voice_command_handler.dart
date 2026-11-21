import 'voice_command_parser.dart';

/// Replaceable with a fresh-frame VLM router later; STT never depends on VLM.
abstract interface class SceneDescriptionSource {
  Future<String> describe();
}

class LocalSceneDescription implements SceneDescriptionSource {
  LocalSceneDescription(this.snapshot);
  final String Function() snapshot;
  @override
  Future<String> describe() async => snapshot();
}

class VoiceCommandHandler {
  VoiceCommandHandler({
    required this.start,
    required this.stop,
    required this.scene,
    required this.previousMessage,
    required this.setWarnings,
  });
  final Future<bool> Function() start;
  final Future<void> Function() stop;
  final SceneDescriptionSource scene;
  final String Function() previousMessage;
  final void Function(bool) setWarnings;
  bool _busy = false;

  Future<String> handle(String transcript) =>
      handleCommand(VoiceCommandParser.parse(transcript));

  Future<String> handleCommand(VoiceCommand command) async {
    if (_busy) return 'Предыдущая команда ещё выполняется';
    _busy = true;
    try {
      switch (command) {
        case VoiceCommand.start:
          return await start()
              ? 'Обнаружение запущено'
              : 'Не удалось запустить обнаружение';
        case VoiceCommand.stop:
          await stop();
          return 'Обнаружение остановлено';
        case VoiceCommand.describe:
          try {
            return await scene.describe().timeout(const Duration(seconds: 3));
          } catch (_) {
            return 'Актуальное описание недоступно';
          }
        case VoiceCommand.describeEnvironment:
          // The router exposes the VLM intent; no VLM service exists yet.
          return 'Описание окружения пока недоступно';
        case VoiceCommand.repeat:
          final previous = previousMessage();
          return previous.isEmpty
              ? 'Пока нечего повторять'
              : 'Повтор предыдущего сообщения: $previous';
        case VoiceCommand.enableWarnings:
          setWarnings(true);
          return 'Автоматические предупреждения включены';
        case VoiceCommand.disableWarnings:
          setWarnings(false);
          return 'Автоматические предупреждения выключены';
        case VoiceCommand.help:
          return 'Нажмите микрофон и скажите: начать, остановить, что впереди или повтори';
        case VoiceCommand.unknown:
          return 'Команда не распознана';
      }
    } finally {
      _busy = false;
    }
  }
}
