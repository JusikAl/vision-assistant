import 'package:web_socket_channel/web_socket_channel.dart';

enum DetectionMode { unavailable, offline, connected }

/// Only negotiates availability/state. Camera and detection results stay
/// in LiveCameraPage, so the existing server protocol is unchanged.
class DetectionModeManager {
  DetectionMode mode = DetectionMode.unavailable;
  String? lastConnectionError;

  bool get isOffline => mode == DetectionMode.offline;
  bool get isConnected => mode == DetectionMode.connected;

  Future<WebSocketChannel?> tryConnect(String url) async {
    WebSocketChannel? channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready.timeout(const Duration(seconds: 3));
      lastConnectionError = null;
      return channel;
    } catch (error) {
      lastConnectionError = error.toString();
      try {
        await channel?.sink.close().timeout(const Duration(milliseconds: 600));
      } catch (_) {}
      return null;
    }
  }

  void setConnected() => mode = DetectionMode.connected;
  void setOffline() => mode = DetectionMode.offline;
  void setUnavailable() => mode = DetectionMode.unavailable;
}
