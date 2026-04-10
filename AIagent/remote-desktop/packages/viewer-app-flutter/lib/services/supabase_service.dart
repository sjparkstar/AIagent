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

  Future<DashboardStats> loadStats() async {
    try {
      final today = DateTime.now();
      final todayStr =
          '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

      final allRows = await _client
          .from('sessions')
          .select('id, started_at, ended_at')
          .not('ended_at', 'is', null);

      final todayRows = await _client
          .from('sessions')
          .select('id')
          .gte('started_at', todayStr);

      int totalDuration = 0;
      for (final row in allRows) {
        final start = DateTime.tryParse(row['started_at']?.toString() ?? '');
        final end = DateTime.tryParse(row['ended_at']?.toString() ?? '');
        if (start != null && end != null) {
          totalDuration += end.difference(start).inMinutes;
        }
      }

      final total = allRows.length;
      final avgDur = total > 0 ? (totalDuration ~/ total) : 0;

      return DashboardStats(
        totalSessions: total,
        todaySessions: todayRows.length,
        avgDurationMin: avgDur,
        avgRttMs: 0,
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

  Future<List<SessionInfo>> loadRecentSessions({int limit = 20}) async {
    try {
      final rows = await _client
          .from('sessions')
          .select('id, room_id, started_at, ended_at, end_reason')
          .order('started_at', ascending: false)
          .limit(limit);

      return rows.map<SessionInfo>((row) {
        return SessionInfo(
          id: row['id']?.toString() ?? '',
          roomId: row['room_id']?.toString() ?? '',
          startedAt:
              DateTime.tryParse(row['started_at']?.toString() ?? '') ??
                  DateTime.now(),
          endedAt:
              DateTime.tryParse(row['ended_at']?.toString() ?? ''),
          endReason: row['end_reason']?.toString(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> startSession(String roomId, String viewerId) async {
    try {
      final result = await _client
          .from('sessions')
          .insert({
            'room_id': roomId,
            'viewer_id': viewerId,
            'started_at': DateTime.now().toIso8601String(),
          })
          .select('id')
          .single();
      _activeSessionId = result['id']?.toString();
    } catch (_) {}
  }

  Future<void> endSession(String reason) async {
    if (_activeSessionId == null) return;
    try {
      await _client.from('sessions').update({
        'ended_at': DateTime.now().toIso8601String(),
        'end_reason': reason,
      }).eq('id', _activeSessionId!);
      _activeSessionId = null;
    } catch (_) {}
  }
}
