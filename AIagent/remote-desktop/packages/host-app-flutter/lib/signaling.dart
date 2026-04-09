import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _connected = false;

  Function(Map<String, dynamic>)? onMessage;
  Function()? onDisconnected;

  bool get isConnected => _connected;

  Future<void> connect(String url) async {
    _channel = WebSocketChannel.connect(Uri.parse(url));

    await _channel!.ready;
    _connected = true;

    _subscription = _channel!.stream.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          onMessage?.call(msg);
        } catch (e) {
          debugPrint('[signaling] 메시지 파싱 오류: $e');
        }
      },
      onDone: () {
        _connected = false;
        onDisconnected?.call();
      },
      onError: (e) {
        _connected = false;
        debugPrint('[signaling] 오류: $e');
        onDisconnected?.call();
      },
    );
  }

  void send(Map<String, dynamic> msg) {
    if (!_connected || _channel == null) {
      debugPrint('[signaling] 연결되지 않은 상태에서 전송 시도 무시');
      return;
    }
    _channel!.sink.add(jsonEncode(msg));
  }

  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _connected = false;
  }
}
