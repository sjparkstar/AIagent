import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../services/supabase_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardStats? _stats;
  List<SessionInfo> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final svc = SupabaseService.instance;
    final stats = await svc.loadStats();
    final sessions = await svc.loadRecentSessions();
    if (mounted) {
      setState(() {
        _stats = stats;
        _sessions = sessions;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgPrimary,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: accent),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildStatsRow(),
                        const SizedBox(height: 24),
                        _buildConnectButton(),
                        const SizedBox(height: 24),
                        _buildSessionList(),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: bgSecondary,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: const Row(
        children: [
          Icon(Icons.desktop_windows_outlined, color: accent, size: 20),
          SizedBox(width: 10),
          Text(
            'RemoteCall-mini Viewer',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final stats = _stats;
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            label: '총 상담',
            value: '${stats?.totalSessions ?? 0}건',
            icon: Icons.history,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            label: '오늘 상담',
            value: '${stats?.todaySessions ?? 0}건',
            icon: Icons.today,
            color: success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            label: '평균 시간',
            value: '${stats?.avgDurationMin ?? 0}분',
            icon: Icons.timer_outlined,
            color: warning,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            label: '평균 RTT',
            value: '${stats?.avgRttMs ?? 0}ms',
            icon: Icons.network_check,
            color: accent,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required String label,
    required String value,
    required IconData icon,
    Color color = textSecondary,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: textSecondary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color == textSecondary ? textPrimary : color,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton.icon(
        onPressed: () =>
            Navigator.of(context).pushNamed('/waiting'),
        icon: const Icon(Icons.link, size: 18),
        label: const Text(
          '상담 연결',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildSessionList() {
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '최근 상담 이력',
              style: TextStyle(
                color: textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Divider(color: borderColor, height: 1),
          if (_sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  '상담 이력이 없습니다.',
                  style: TextStyle(color: textSecondary, fontSize: 13),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _sessions.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: borderColor, height: 1),
              itemBuilder: (_, index) => _buildSessionRow(_sessions[index]),
            ),
        ],
      ),
    );
  }

  Widget _buildSessionRow(SessionInfo session) {
    final ended = session.endedAt != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ended ? textSecondary : success,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '방 번호: ${session.roomId}',
                  style: const TextStyle(color: textPrimary, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatDateTime(session.startedAt),
                  style:
                      const TextStyle(color: textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            ended ? '${session.durationMin}분' : '진행 중',
            style: TextStyle(
              color: ended ? textSecondary : success,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
