import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class SocketService {
  static IO.Socket? _socket;
  
  static String get socketUrl {
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host != 'localhost' && host != '127.0.0.1' && host.isNotEmpty) {
        return Uri.base.origin;
      }
    }
    return 'http://localhost:3100';
  }
  
  static IO.Socket get instance {
    if (_socket == null) {
      final isProdWeb = kIsWeb && Uri.base.host != 'localhost' && Uri.base.host != '127.0.0.1' && Uri.base.host.isNotEmpty;
      final opts = IO.OptionBuilder()
        .setTransports(isProdWeb ? ['polling'] : ['websocket', 'polling'])
        .setUpgrade(!isProdWeb)
        .disableAutoConnect()
        .build();

      _socket = IO.io(socketUrl, opts);
      _socket!.connect();
    }
    return _socket!;
  }

  static IO.Socket? get socket {
    try {
      return instance;
    } catch (_) {
      return null;
    }
  }

  static void on(String event, Function(dynamic) handler) {
    instance.on(event, handler);
  }

  static void emit(String event, [dynamic data]) {
    instance.emit(event, data);
  }

  static void off(String event) {
    instance.off(event);
  }
}
