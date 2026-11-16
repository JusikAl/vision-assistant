import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolo_live_detection/services/detection_mode_manager.dart';

void main() {
  test(
    'local WebSocket handshake preserves online/offline negotiation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? peer;
      final requests = server.listen((request) async {
        peer = await WebSocketTransformer.upgrade(request);
        peer!.listen((_) {});
      });
      final manager = DetectionModeManager();
      final channel = await manager.tryConnect('ws://127.0.0.1:${server.port}');
      try {
        expect(channel, isNotNull);
        expect(manager.lastConnectionError, isNull);
        manager.setConnected();
        expect(manager.isConnected, isTrue);
        manager.setOffline();
        expect(manager.isOffline, isTrue);
        manager.setUnavailable();
        expect(manager.isConnected, isFalse);
        expect(manager.isOffline, isFalse);
      } finally {
        await channel?.sink.close();
        await peer?.close();
        await requests.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'rejected server handshake does not claim connected detection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = server.listen((request) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.close();
      });
      try {
        final manager = DetectionModeManager();
        final channel = await manager.tryConnect(
          'ws://127.0.0.1:${server.port}',
        );
        expect(channel, isNull);
        expect(manager.isConnected, isFalse);
        expect(manager.lastConnectionError, isNotEmpty);
      } finally {
        await requests.cancel();
        await server.close(force: true);
      }
    },
  );
}
