import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  AppConfig._();

  static Future<void>? _loadFuture;

  // Загрузка конфигурации из .env
  static Future<void> load() {
    return _loadFuture ??= dotenv.load(fileName: '.env');
  }

  // IP сервера
  static String get serverHost {
    return dotenv.env['SERVER_HOST']?.trim() ?? '192.168.10.3';
  }

  // Порт сервера
  static int get serverPort {
    return int.tryParse(dotenv.env['SERVER_PORT']?.trim() ?? '8000') ?? 8000;
  }

  // HTTP
  static String get httpBaseUrl {
    return 'http://$serverHost:$serverPort';
  }

  // WebSocket
  static String get wsBaseUrl {
    return 'ws://$serverHost:$serverPort';
  }

  // YOLO + Depth
  static String get wsDetectUrl {
    return '$wsBaseUrl/ws/detect';
  }

  // HTTP detection
  static String get detectUrl {
    return '$httpBaseUrl/detect';
  }

  // Server health
  static String get healthUrl {
    return '$httpBaseUrl/health';
  }

  // VLM is independent of the detection mode and its WebSocket connection.
  static Uri get vlmBaseUrl {
    const override = String.fromEnvironment('VLM_BASE_URL');
    final value = override.isNotEmpty
        ? override
        : dotenv.env['VLM_BASE_URL']?.trim();
    final uri = Uri.parse(value == null || value.isEmpty ? httpBaseUrl : value);
    if (!const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid VLM_BASE_URL');
    }
    return uri;
  }
}
