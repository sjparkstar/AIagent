import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ??????????????????????????????????????????????????????????????
// 梨꾪똿 硫붿떆吏 紐⑤뜽 (Supabase chat_messages ?뚯씠釉?援ъ“? ???
// ??????????????????????????????????????????????????????????????
class ChatRoomMessage {
  final String id;
  final String chatRoomId;
  final String senderId;
  final String senderType; // 'host' / 'viewer' / 'system' / 'bot'
  final String content;
  final String messageType; // 'text' / 'system' / 'file'
  final DateTime createdAt;
  // 스레드(답글) 정보
  final String? parentMessageId; // null이면 일반 메시지(스레드 루트)
  final int replyCount;          // 부모일 때 답글 수, 답글 자신은 0

  const ChatRoomMessage({
    required this.id,
    required this.chatRoomId,
    required this.senderId,
    required this.senderType,
    required this.content,
    required this.messageType,
    required this.createdAt,
    this.parentMessageId,
    this.replyCount = 0,
  });

  factory ChatRoomMessage.fromJson(Map<String, dynamic> json) {
    return ChatRoomMessage(
      id: json['id']?.toString() ?? '',
      chatRoomId: json['chat_room_id']?.toString() ?? json['chatRoomId']?.toString() ?? '',
      senderId: json['sender_id']?.toString() ?? json['senderId']?.toString() ?? '',
      senderType: json['sender_type']?.toString() ?? json['senderType']?.toString() ?? 'viewer',
      content: json['content']?.toString() ?? '',
      messageType: json['message_type']?.toString() ?? json['messageType']?.toString() ?? 'text',
      createdAt: _parseDate(json['created_at']?.toString() ?? json['createdAt']?.toString()),
      parentMessageId: (json['parent_message_id'] ?? json['parentMessageId'])?.toString(),
      replyCount: (json['reply_count'] ?? json['replyCount']) is num
          ? ((json['reply_count'] ?? json['replyCount']) as num).toInt()
          : 0,
    );
  }

  // 부분 갱신용 copyWith (예: replyCount만 +1)
  ChatRoomMessage copyWith({int? replyCount}) {
    return ChatRoomMessage(
      id: id,
      chatRoomId: chatRoomId,
      senderId: senderId,
      senderType: senderType,
      content: content,
      messageType: messageType,
      createdAt: createdAt,
      parentMessageId: parentMessageId,
      replyCount: replyCount ?? this.replyCount,
    );
  }

  static DateTime _parseDate(String? raw) {
    if (raw == null || raw.isEmpty) return DateTime.now();
    return DateTime.tryParse(raw) ?? DateTime.now();
  }
}

class ChatService {
  final String serverUrl;
  final String userId;
  final String userType;

  String? chatRoomId;

  Function(ChatRoomMessage msg)? onMessage;
  Function(String userId)? onTyping;
  Function(String userId, String lastReadAt)? onReadUpdate;

  ChatService({
    required this.serverUrl,
    required this.userId,
    required this.userType,
  });

  Future<String?> createOrJoinRoom(
    String sessionId,
    List<String> participantIds,
  ) async {
    try {
      final resp = await http.post(
        Uri.parse('$serverUrl/api/chat/rooms'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'sessionId': sessionId,
          'roomType': 'direct',
          'participantIds': participantIds,
        }),
      );
      if (resp.statusCode == 201) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return body['id']?.toString();
      }
      debugPrint('[chat] createOrJoinRoom ?ㅽ뙣: ${resp.statusCode} ${resp.body}');
    } catch (e) {
      debugPrint('[chat] createOrJoinRoom ?ㅻ쪟: $e');
    }
    return null;
  }

  Future<List<ChatRoomMessage>> loadMessages({
    String? before,
    int limit = 30,
  }) async {
    final id = chatRoomId;
    if (id == null) return [];

    try {
      var url = '$serverUrl/api/chat/rooms/$id/messages?limit=$limit';
      if (before != null) url += '&before=${Uri.encodeComponent(before)}';

      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final rows = jsonDecode(resp.body) as List<dynamic>;
        return rows
            .map((r) => ChatRoomMessage.fromJson(r as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[chat] loadMessages ?ㅻ쪟: $e');
    }
    return [];
  }

  // 특정 메시지의 답글 목록 조회
  Future<List<ChatRoomMessage>> loadReplies(String parentMessageId) async {
    try {
      final url = '$serverUrl/api/chat/messages/$parentMessageId/replies';
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final rows = jsonDecode(resp.body) as List<dynamic>;
        return rows
            .map((r) => ChatRoomMessage.fromJson(r as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[chat] loadReplies 오류: $e');
    }
    return [];
  }

  Future<void> markAsRead() async {
    final id = chatRoomId;
    if (id == null) return;
    try {
      await http.put(
        Uri.parse('$serverUrl/api/chat/rooms/$id/read'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': userId}),
      );
    } catch (e) {
      debugPrint('[chat] markAsRead ?ㅻ쪟: $e');
    }
  }

  void handleIncomingWsMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    switch (type) {
      case 'chat-message-broadcast':
        onMessage?.call(ChatRoomMessage.fromJson(msg));
        return;

      case 'chat-typing-broadcast':
        final uid = msg['userId']?.toString() ?? '';
        if (uid.isNotEmpty) onTyping?.call(uid);
        return;

      case 'chat-read-broadcast':
        final readerId = msg['userId']?.toString() ?? '';
        final at = msg['lastReadAt']?.toString() ?? '';
        if (readerId.isNotEmpty) onReadUpdate?.call(readerId, at);
        return;

      default:
        return;
    }
  }
}
