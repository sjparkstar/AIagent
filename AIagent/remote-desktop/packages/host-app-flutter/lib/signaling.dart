import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingClient {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeat;
  bool _connected = false;

  Function(Map<String, dynamic>)? onMessage;
  Function()? onDisconnected;
  // 채팅 메시지 브로드캐스트 수신 콜백
  Function(Map<String, dynamic> msg)? onChatMessage;

  bool get isConnected => _connected;

  Future<void> connect(String url) async {
    _channel = WebSocketChannel.connect(Uri.parse(url));

    await _channel!.ready;
    _connected = true;

    // 10초마다 응용 레벨 ping으로 연결 유지
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_connected && _channel != null) {
        _channel!.sink.add(jsonEncode({'type': 'ping'}));
      }
    });

    _subscription = _channel!.stream.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          final type = msg['type'] as String?;
          // 채팅 관련 브로드캐스트는 별도 콜백으로 위임
          if (type == 'chat-message-broadcast' ||
              type == 'chat-read-broadcast' ||
              type == 'chat-typing-broadcast') {
            onChatMessage?.call(msg);
          } else {
            onMessage?.call(msg);
          }
        } catch (e) {
          debugPrint('[signaling] 메시지 파싱 오류: $e');
        }
      },
      onDone: () {
        _connected = false;
        _heartbeat?.cancel();
        onDisconnected?.call();
      },
      onError: (e) {
        _connected = false;
        _heartbeat?.cancel();
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

  // 채팅 메시지를 시그널링 WS로 전송
  void sendChatMessage(Map<String, dynamic> chatMsg) {
    send(chatMsg);
  }

  void disconnect() {
    _heartbeat?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _connected = false;
  }
}
