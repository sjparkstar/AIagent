import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ViewerSignaling {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _connected = false;

  Function(String roomId)? onHostReady;
  Function(String viewerId)? onViewerJoined;
  Function(Map<String, dynamic> sdp)? onAnswer;
  Function(Map<String, dynamic> candidate)? onIceCandidate;
  Function(String code, String message)? onError;
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
          _handleMessage(msg);
        } catch (e) {
          debugPrint('[signaling] 메시지 파싱 오류: $e');
        }
      },
      onDone: () {
        _connected = false;
        onDisconnected?.call();
      },
      onError: (dynamic e) {
        _connected = false;
        debugPrint('[signaling] 오류: $e');
        onDisconnected?.call();
      },
    );
  }

  void register(String password) {
    _send({'type': 'register', 'passwordHash': password});
  }

  void sendOffer(Map<String, dynamic> sdp, String viewerId) {
    _send({'type': 'offer', 'sdp': sdp, 'viewerId': viewerId});
  }

  void sendIceCandidate(Map<String, dynamic> candidate, String viewerId) {
    _send({'type': 'ice-candidate', 'candidate': candidate, 'viewerId': viewerId});
  }

  void disconnect() {
    _subscription?.cancel();
    _channel?.sink.close();
    _connected = false;
  }

  void _send(Map<String, dynamic> msg) {
    if (!_connected || _channel == null) {
      debugPrint('[signaling] 연결되지 않은 상태에서 전송 무시');
      return;
    }
    _channel!.sink.add(jsonEncode(msg));
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    debugPrint('[signaling] 수신: $type');

    switch (type) {
      case 'host-ready':
        final roomId = msg['roomId']?.toString() ?? '';
        onHostReady?.call(roomId);

      case 'viewer-joined':
        final viewerId = msg['viewerId']?.toString() ?? '';
        onViewerJoined?.call(viewerId);

      case 'answer':
        final sdp = msg['sdp'] as Map<String, dynamic>?;
        if (sdp != null) onAnswer?.call(sdp);

      case 'ice-candidate':
        final candidate = msg['candidate'] as Map<String, dynamic>?;
        if (candidate != null) onIceCandidate?.call(candidate);

      case 'error':
        final code = msg['code']?.toString() ?? 'UNKNOWN';
        final message = msg['message']?.toString() ?? '알 수 없는 오류';
        onError?.call(code, message);

      default:
        debugPrint('[signaling] 처리되지 않은 메시지: $type');
    }
  }
}
