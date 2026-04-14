import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ViewerSignaling {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  bool _connected = false;

  Function(String roomId)? onHostReady;
  Function(String viewerId)? onViewerJoined;
  Function(Map<String, dynamic> sdp)? onAnswer;
  Function(Map<String, dynamic> candidate)? onIceCandidate;
  Function(String code, String message)? onError;
  Function()? onDisconnected;
  // 호스트 앱이 접속 요청을 보냈을 때 호출 (승인 다이얼로그 표시용)
  Function(String viewerId)? onHostJoinRequest;
  // 梨꾪똿 硫붿떆吏 釉뚮줈?쒖틦?ㅽ듃 ?섏떊 肄쒕갚
  Function(Map<String, dynamic> msg)? onChatMessage;
  // ?먮룞吏꾨떒/蹂듦뎄 硫붿떆吏 ?섏떊 肄쒕갚 (issue.notified, diagnostic.result, recovery.result ??
  Function(Map<String, dynamic> msg)? onDiagnosisMessage;

  bool get isConnected => _connected;

  Future<void> connect(String url) async {
    _channel = WebSocketChannel.connect(Uri.parse(url));
    await _channel!.ready;
    _connected = true;

    // 10珥덈쭏???묒슜 ?덈꺼 ping???꾩넚?섏뿬 ?곌껐 ?좎?
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_connected && _channel != null) {
        _channel!.sink.add(jsonEncode({'type': 'ping'}));
      }
    });

    _subscription = _channel!.stream.listen(
      (data) {
        try {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          _handleMessage(msg);
        } catch (e) {
          debugPrint('[signaling] 硫붿떆吏 ?뚯떛 ?ㅻ쪟: $e');
        }
      },
      onDone: () {
        _connected = false;
        _heartbeat?.cancel();
        onDisconnected?.call();
      },
      onError: (dynamic e) {
        _connected = false;
        _heartbeat?.cancel();
        debugPrint('[signaling] ?ㅻ쪟: $e');
        onDisconnected?.call();
      },
    );
  }

  // password 방식 폐지 — register 시 인자 없이 방만 생성
  void register() {
    _send({'type': 'register'});
  }

  // 호스트 접속 요청 승인/거부 응답 전송
  void sendApproveHost(String viewerId, bool approved) {
    _send({'type': 'approve-host', 'viewerId': viewerId, 'approved': approved});
  }

  void sendOffer(Map<String, dynamic> sdp, String viewerId) {
    _send({'type': 'offer', 'sdp': sdp, 'viewerId': viewerId});
  }

  void sendIceCandidate(Map<String, dynamic> candidate, String viewerId) {
    _send({'type': 'ice-candidate', 'candidate': candidate, 'viewerId': viewerId});
  }

  // 梨꾪똿 硫붿떆吏瑜??쒓렇?먮쭅 WS濡??꾩넚 (?쒕쾭??chat-ws.ts媛 泥섎━)
  void sendChatMessage(Map<String, dynamic> chatMsg) {
    _send(chatMsg);
  }

  // 踰붿슜 硫붿떆吏 ?꾩넚 (?먮룞吏꾨떒/蹂듦뎄 硫붿떆吏 ??
  void send(Map<String, dynamic> msg) {
    _send(msg);
  }

  void disconnect() {
    _heartbeat?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _connected = false;
  }

  void _send(Map<String, dynamic> msg) {
    if (!_connected || _channel == null) {
      debugPrint('[signaling] ?곌껐?섏? ?딆? ?곹깭?먯꽌 ?꾩넚 臾댁떆');
      return;
    }
    _channel!.sink.add(jsonEncode(msg));
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    debugPrint('[signaling] ?섏떊: $type');

    switch (type) {
      case 'host-ready':
        onHostReady?.call(msg['roomId']?.toString() ?? '');
        return;

      case 'viewer-joined':
        onViewerJoined?.call(msg['viewerId']?.toString() ?? '');
        return;

      // 호스트 앱이 접속 요청을 보냄 → 승인 다이얼로그 표시
      case 'host-join-request':
        onHostJoinRequest?.call(msg['viewerId']?.toString() ?? '');
        return;

      case 'answer':
        final sdp = msg['sdp'] as Map<String, dynamic>?;
        if (sdp != null) onAnswer?.call(sdp);
        return;

      case 'ice-candidate':
        final candidate = msg['candidate'] as Map<String, dynamic>?;
        if (candidate != null) onIceCandidate?.call(candidate);
        return;

      case 'error':
        onError?.call(
          msg['code']?.toString() ?? 'UNKNOWN',
          msg['message']?.toString() ?? '?????녿뒗 ?ㅻ쪟',
        );
        return;

      // 梨꾪똿 愿??釉뚮줈?쒖틦?ㅽ듃??onChatMessage 肄쒕갚?쇰줈 ?꾩엫
      case 'chat-message-broadcast':
      case 'chat-read-broadcast':
      case 'chat-typing-broadcast':
        onChatMessage?.call(msg);
        return;

      // ?먮룞吏꾨떒/蹂듦뎄 愿??釉뚮줈?쒖틦?ㅽ듃??onDiagnosisMessage濡??꾩엫
      case 'issue.notified':
      case 'diagnostic.progress':
      case 'diagnostic.result':
      case 'recovery.progress':
      case 'recovery.result':
      case 'verification.result':
        onDiagnosisMessage?.call(msg);
        return;

      default:
        debugPrint('[signaling] 泥섎━?섏? ?딆? 硫붿떆吏: $type');
        return;
    }
  }
}
