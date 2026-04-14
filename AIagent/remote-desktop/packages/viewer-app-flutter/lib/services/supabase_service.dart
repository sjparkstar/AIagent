import 'package:supabase_flutter/supabase_flutter.dart';

class DashboardStats {
  final int totalSessions;
  final int todaySessions;
  final int avgDurationMin;
  final int avgRttMs;

  const DashboardStats({
    required this.totalSessions,
    required this.todaySessions,
    required this.avgDurationMin,
    required this.avgRttMs,
  });
}

class SessionInfo {
  final String id;
  final String roomId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? endReason;

  const SessionInfo({
    required this.id,
    required this.roomId,
    required this.startedAt,
    this.endedAt,
    this.endReason,
  });

  int get durationMin {
    final end = endedAt ?? DateTime.now();
    return end.difference(startedAt).inMinutes;
  }
}

// 세션 상세 정보를 담는 모델 클래스
class SessionDetail {
  final String id;
  final String roomId;
  final DateTime? connectedAt;
  final DateTime? disconnectedAt;
  final String? disconnectReason;
  final int? reconnectCount;
  // 호스트(상담사 PC) 정보
  final String? hostOs;
  final String? hostOsVersion;
  final String? hostCpuModel;
  final int? hostMemTotalMb;
  // 뷰어(고객) 정보
  final String? viewerUserAgent;
  final int? viewerScreenWidth;
  final int? viewerScreenHeight;
  final String? viewerLanguage;
  // 연결 품질 지표
  final int? avgBitrateKbps;
  final double? avgFramerate;
  final int? avgRttMs;
  final int? totalPacketsLost;
  final int? totalBytesReceived;
  // 녹화 및 PDF
  final String? recordingUrl;
  final String? pdfUrl;

  const SessionDetail({
    required this.id,
    required this.roomId,
    this.connectedAt,
    this.disconnectedAt,
    this.disconnectReason,
    this.reconnectCount,
    this.hostOs,
    this.hostOsVersion,
    this.hostCpuModel,
    this.hostMemTotalMb,
    this.viewerUserAgent,
    this.viewerScreenWidth,
    this.viewerScreenHeight,
    this.viewerLanguage,
    this.avgBitrateKbps,
    this.avgFramerate,
    this.avgRttMs,
    this.totalPacketsLost,
    this.totalBytesReceived,
    this.recordingUrl,
    this.pdfUrl,
  });

  // 상담 지속 시간(분 단위)을 계산하는 getter
  int get durationMin {
    if (connectedAt == null) return 0;
    final end = disconnectedAt ?? DateTime.now();
    return end.difference(connectedAt!).inMinutes;
  }
}

// AI 어시스턴트 대화 로그를 담는 모델 클래스
class AssistantLog {
  final String id;
  final String role;
  final String content;
  final DateTime createdAt;

  const AssistantLog({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });
}

// 실제 Supabase 테이블명: connection_sessions (Electron 뷰어와 동일)
const _tSessions = 'connection_sessions';
const _tLogs = 'assistant_logs';

class SupabaseService {
  static const _supabaseUrl = 'https://xrvbktzsxtgadrcwhxkl.supabase.co';
  static const _supabaseKey =
      'sb_publishable_aL9Oh6wdJEdE_xO8lC3hHA_yx-ac2YQ';

  static SupabaseService? _instance;

  SupabaseService._();

  static SupabaseService get instance {
    _instance ??= SupabaseService._();
    return _instance!;
  }

  static Future<void> initialize() async {
    await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseKey);
  }

  SupabaseClient get _client => Supabase.instance.client;

  String? _activeSessionId;

  // 대시보드 통계 조회
  Future<DashboardStats> loadStats() async {
    try {
      final allRows = await _client
          .from(_tSessions)
          .select('id, connected_at, disconnected_at')
          .not('disconnected_at', 'is', null);

      final today = DateTime.now();
      final todayStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      final todayRows = await _client
          .from(_tSessions)
          .select('id')
          .gte('connected_at', todayStr);

      int totalDuration = 0;
      int totalRtt = 0;
      int rttCount = 0;
      for (final row in allRows) {
        final start = DateTime.tryParse(row['connected_at']?.toString() ?? '');
        final end = DateTime.tryParse(row['disconnected_at']?.toString() ?? '');
        if (start != null && end != null) {
          totalDuration += end.difference(start).inMinutes;
        }
        final rtt = row['avg_rtt_ms'] as int?;
        if (rtt != null) {
          totalRtt += rtt;
          rttCount++;
        }
      }

      final total = allRows.length;
      final avgDur = total > 0 ? (totalDuration ~/ total) : 0;
      final avgRtt = rttCount > 0 ? (totalRtt ~/ rttCount) : 0;

      return DashboardStats(
        totalSessions: total,
        todaySessions: todayRows.length,
        avgDurationMin: avgDur,
        avgRttMs: avgRtt,
      );
    } catch (_) {
      return const DashboardStats(
        totalSessions: 0,
        todaySessions: 0,
        avgDurationMin: 0,
        avgRttMs: 0,
      );
    }
  }

  // 최근 세션 목록 조회
  Future<List<SessionInfo>> loadRecentSessions({int limit = 20}) async {
    try {
      final rows = await _client
          .from(_tSessions)
          .select('id, room_id, connected_at, disconnected_at, disconnect_reason')
          .order('connected_at', ascending: false)
          .limit(limit);

      return rows.map<SessionInfo>((row) {
        return SessionInfo(
          id: row['id']?.toString() ?? '',
          roomId: row['room_id']?.toString() ?? '',
          startedAt:
              DateTime.tryParse(row['connected_at']?.toString() ?? '') ??
                  DateTime.now(),
          endedAt:
              DateTime.tryParse(row['disconnected_at']?.toString() ?? ''),
          endReason: row['disconnect_reason']?.toString(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // 현재 활성 세션 ID를 외부에서 읽을 수 있도록 getter 제공
  String? get activeSessionId => _activeSessionId;

  // 세션 시작 (뷰어-호스트 연결 시 호출)
  Future<void> startSession(String roomId, String viewerId) async {
    try {
      final result = await _client
          .from(_tSessions)
          .insert({
            'room_id': roomId,
            'viewer_id': viewerId,
          })
          .select('id')
          .single();
      _activeSessionId = result['id']?.toString();
    } catch (_) {}
  }

  // 세션 종료 (연결 해제 시 호출)
  Future<void> endSession(String reason) async {
    if (_activeSessionId == null) return;
    try {
      await _client.from(_tSessions).update({
        'disconnected_at': DateTime.now().toIso8601String(),
        'disconnect_reason': reason,
      }).eq('id', _activeSessionId!);
      _activeSessionId = null;
    } catch (_) {}
  }

  // 호스트 시스템 정보 업데이트
  Future<void> updateHostInfo({
    required String hostOs,
    String? hostOsVersion,
    String? hostCpuModel,
    int? hostMemTotalMb,
  }) async {
    if (_activeSessionId == null) return;
    try {
      await _client.from(_tSessions).update({
        'host_os': hostOs,
        if (hostOsVersion != null) 'host_os_version': hostOsVersion,
        if (hostCpuModel != null) 'host_cpu_model': hostCpuModel,
        if (hostMemTotalMb != null) 'host_mem_total_mb': hostMemTotalMb,
      }).eq('id', _activeSessionId!);
    } catch (_) {}
  }

  // 녹화 URL 업데이트
  Future<void> updateRecordingUrl(String url) async {
    if (_activeSessionId == null) return;
    try {
      await _client.from(_tSessions).update({
        'recording_url': url,
      }).eq('id', _activeSessionId!);
    } catch (_) {}
  }

  // AI 어시스턴트 대화 로그 기록
  Future<void> logAssistantMessage(
    String role,
    String content, {
    String? source,
    String? query,
    int? docResultsCount,
    int? responseTimeMs,
  }) async {
    if (_activeSessionId == null) return;
    try {
      await _client.from(_tLogs).insert({
        'session_id': _activeSessionId,
        'role': role,
        'content':
            content.length > 5000 ? content.substring(0, 5000) : content,
        'source': source,
        'query': query,
        'doc_results_count': docResultsCount,
        'response_time_ms': responseTimeMs,
      });
    } catch (_) {}
  }

  // 특정 세션의 상세 정보 조회
  Future<SessionDetail?> loadSessionDetail(String sessionId) async {
    try {
      final row = await _client
          .from(_tSessions)
          .select(
            'id, room_id, connected_at, disconnected_at, disconnect_reason, reconnect_count, '
            'host_os, host_os_version, host_cpu_model, host_mem_total_mb, '
            'viewer_user_agent, viewer_screen_width, viewer_screen_height, viewer_language, '
            'avg_bitrate_kbps, avg_framerate, avg_rtt_ms, total_packets_lost, total_bytes_received, '
            'recording_url, pdf_url',
          )
          .eq('id', sessionId)
          .single();

      return SessionDetail(
        id: row['id']?.toString() ?? '',
        roomId: row['room_id']?.toString() ?? '',
        connectedAt: DateTime.tryParse(row['connected_at']?.toString() ?? ''),
        disconnectedAt: DateTime.tryParse(row['disconnected_at']?.toString() ?? ''),
        disconnectReason: row['disconnect_reason']?.toString(),
        reconnectCount: row['reconnect_count'] as int?,
        hostOs: row['host_os']?.toString(),
        hostOsVersion: row['host_os_version']?.toString(),
        hostCpuModel: row['host_cpu_model']?.toString(),
        hostMemTotalMb: row['host_mem_total_mb'] as int?,
        viewerUserAgent: row['viewer_user_agent']?.toString(),
        viewerScreenWidth: row['viewer_screen_width'] as int?,
        viewerScreenHeight: row['viewer_screen_height'] as int?,
        viewerLanguage: row['viewer_language']?.toString(),
        avgBitrateKbps: row['avg_bitrate_kbps'] as int?,
        avgFramerate: (row['avg_framerate'] as num?)?.toDouble(),
        avgRttMs: row['avg_rtt_ms'] as int?,
        totalPacketsLost: row['total_packets_lost'] as int?,
        totalBytesReceived: row['total_bytes_received'] as int?,
        recordingUrl: row['recording_url']?.toString(),
        pdfUrl: row['pdf_url']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  // 특정 세션의 AI 어시스턴트 대화 로그 조회
  Future<List<AssistantLog>> loadAssistantLogs(String sessionId) async {
    try {
      final rows = await _client
          .from(_tLogs)
          .select('id, role, content, created_at')
          .eq('session_id', sessionId)
          .order('created_at', ascending: true);

      return rows.map<AssistantLog>((row) {
        return AssistantLog(
          id: row['id']?.toString() ?? '',
          role: row['role']?.toString() ?? 'user',
          content: row['content']?.toString() ?? '',
          createdAt:
              DateTime.tryParse(row['created_at']?.toString() ?? '') ??
                  DateTime.now(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
