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
    return dotenv.env['SERVER_HOST']?.trim() ?? '192.168.8.57';
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
}
