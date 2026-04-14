import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_theme.dart';
import '../services/supabase_service.dart';
import '../services/assistant_service.dart';
import '../services/issue_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  DashboardStats? _stats;
  List<SessionInfo> _sessions = [];
  bool _loading = true;

  // 매크로/플레이북 관리에 사용할 서비스 인스턴스 (serverUrl은 Supabase 직접 접근이므로 빈 문자열)
  final _svc = AssistantService(serverUrl: '');

  List<MacroItem> _macros = [];
  List<PlaybookItem> _playbooks = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // 통계, 세션, 매크로, 플레이북을 한 번에 병렬 로드
  Future<void> _loadData() async {
    final svc = SupabaseService.instance;
    final results = await Future.wait([
      svc.loadStats(),
      svc.loadRecentSessions(),
      _svc.fetchAllMacros(),
      _svc.fetchAllPlaybooks(),
    ]);

    if (mounted) {
      setState(() {
        _stats = results[0] as DashboardStats?;
        _sessions = results[1] as List<SessionInfo>;
        _macros = results[2] as List<MacroItem>;
        _playbooks = results[3] as List<PlaybookItem>;
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
                        // 좌우 2컬럼: 왼쪽 상담 이력 / 오른쪽 매크로+플레이북
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 왼쪽: 최근 상담 이력
                            Expanded(flex: 1, child: _buildSessionList()),
                            const SizedBox(width: 16),
                            // 오른쪽: 매크로 + 플레이북 관리
                            Expanded(
                              flex: 1,
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  _buildMacroSection(),
                                  const SizedBox(height: 16),
                                  _buildPlaybookSection(),
                                ],
                              ),
                            ),
                          ],
                        ),
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
      child: Row(
        children: [
          const Icon(Icons.desktop_windows_outlined, color: accent, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'RemoteCall-mini Viewer',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined,
                color: textSecondary, size: 20),
            tooltip: '환경설정',
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
    );
  }

  Future<void> _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    bool autoRecord = prefs.getBool('autoRecord') ?? true;

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: bgCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              title: const Text('환경설정',
                  style: TextStyle(
                      color: textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('녹화 자동 시작',
                                  style: TextStyle(
                                      color: textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500)),
                              SizedBox(height: 2),
                              Text('상담 연결 시 화면 녹화를\n자동으로 시작합니다.',
                                  style: TextStyle(
                                      color: textSecondary, fontSize: 11)),
                            ],
                          ),
                        ),
                        Switch(
                          value: autoRecord,
                          activeColor: accent,
                          onChanged: (val) {
                            setDialogState(() => autoRecord = val);
                            prefs.setBool('autoRecord', val);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('닫기', style: TextStyle(color: accent)),
                ),
              ],
            );
          },
        );
      },
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
        onPressed: () => Navigator.of(context).pushNamed('/waiting'),
        icon: const Icon(Icons.link, size: 18),
        label: const Text(
          '상담 연결',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────
  // 최근 상담 이력 (기존 코드 그대로, 레이아웃만 좌측 컬럼으로 이동)
  // ──────────────────────────────────────────────

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
    // InkWell로 감싸서 클릭 시 세션 상세 모달을 표시
    return InkWell(
      onTap: () => _showSessionDetail(session),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // 진행 중/종료 상태 표시 점
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
                    style: const TextStyle(color: textSecondary, fontSize: 12),
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
      ),
    );
  }

  // UTC → 로컬 시간으로 변환 후 표시
  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  // ──────────────────────────────────────────────
  // 세션 상세 모달
  // ──────────────────────────────────────────────

  // 녹화/PDF URL의 기본 서버 주소 (나중에 설정에서 변경 가능하도록 상수로 분리)
  static const _signalingServerUrl = 'http://localhost:8080';

  // 세션 행 클릭 시 호출: 상세 정보를 로드한 뒤 모달 표시
  Future<void> _showSessionDetail(SessionInfo session) async {
    // 로딩 인디케이터를 먼저 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: accent),
      ),
    );

    // 세션 상세 + 어시스턴트 로그 + 감사 로그를 병렬 로드
    final svc = SupabaseService.instance;
    final issueService = IssueService(serverUrl: _signalingServerUrl);
    final results = await Future.wait([
      svc.loadSessionDetail(session.id),
      svc.loadAssistantLogs(session.id),
      issueService.loadAuditLogs(sessionId: session.id, limit: 200),
    ]);

    if (!mounted) return;
    Navigator.of(context).pop(); // 로딩 인디케이터 닫기

    final detail = results[0] as SessionDetail?;
    final allLogs = results[1] as List<AssistantLog>;
    final auditLogs = results[2] as List<Map<String, dynamic>>;

    // 매크로/플레이북 실행 로그만 필터링
    const macroKeywords = [
      '매크로 실행', '매크로 완료', '매크로 실패',
      '플레이북 시작', '플레이북 완료', '플레이북 오류',
    ];
    const statusPrefixes = ['✅', '❌', '⏳', '⚠️'];
    final macroLogs = allLogs.where((log) {
      return macroKeywords.any((kw) => log.content.contains(kw)) ||
          statusPrefixes.any((p) => log.content.startsWith(p));
    }).toList();

    // AI 대화 로그는 매크로 로그를 제외한 나머지
    final aiLogs = allLogs.where((log) {
      return !macroKeywords.any((kw) => log.content.contains(kw)) &&
          !statusPrefixes.any((p) => log.content.startsWith(p));
    }).toList();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            const Icon(Icons.info_outline, color: accent, size: 18),
            const SizedBox(width: 8),
            const Text(
              '세션 상세',
              style: TextStyle(
                  color: textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            // 방 번호 배지
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '방 번호: ${session.roomId}',
                style: const TextStyle(color: accent, fontSize: 12),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── 1. 세션 정보 ──
                _detailSection(
                  title: '세션 정보',
                  children: [
                    _detailRow('접속번호', session.id),
                    _detailRow(
                      '연결 시간',
                      detail?.connectedAt != null
                          ? _formatDateTime(detail!.connectedAt!)
                          : '-',
                    ),
                    _detailRow(
                      '종료 시간',
                      detail?.disconnectedAt != null
                          ? _formatDateTime(detail!.disconnectedAt!)
                          : (session.endedAt != null ? '-' : '진행 중'),
                    ),
                    _detailRow(
                      '지속 시간',
                      detail != null
                          ? '${detail.durationMin}분'
                          : '${session.durationMin}분',
                    ),
                    _detailRow(
                      '종료 사유',
                      detail?.disconnectReason ?? session.endReason ?? '-',
                    ),
                    _detailRow(
                      '재연결 수',
                      detail?.reconnectCount != null
                          ? '${detail!.reconnectCount}회'
                          : '-',
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── 2. 뷰어(고객) 정보 ──
                _detailSection(
                  title: '뷰어 정보',
                  children: [
                    _detailRow(
                      '브라우저',
                      detail?.viewerUserAgent ?? '-',
                      maxLines: 2,
                    ),
                    _detailRow(
                      '해상도',
                      (detail?.viewerScreenWidth != null &&
                              detail?.viewerScreenHeight != null)
                          ? '${detail!.viewerScreenWidth} × ${detail.viewerScreenHeight}'
                          : '-',
                    ),
                    _detailRow(
                      '언어',
                      detail?.viewerLanguage ?? '-',
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── 3. 호스트(상담사 PC) 정보 ──
                _detailSection(
                  title: '호스트 정보',
                  children: [
                    _detailRow(
                      'OS',
                      [
                        detail?.hostOs,
                        detail?.hostOsVersion,
                      ].where((v) => v != null && v.isNotEmpty).join(' '),
                    ),
                    _detailRow('CPU', detail?.hostCpuModel ?? '-'),
                    _detailRow(
                      '메모리',
                      detail?.hostMemTotalMb != null
                          ? '${(detail!.hostMemTotalMb! / 1024).toStringAsFixed(1)} GB'
                          : '-',
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── 4. 연결 품질 ──
                _detailSection(
                  title: '연결 품질',
                  children: [
                    _detailRow(
                      '평균 비트레이트',
                      detail?.avgBitrateKbps != null
                          ? '${detail!.avgBitrateKbps} kbps'
                          : '-',
                    ),
                    _detailRow(
                      'FPS',
                      detail?.avgFramerate != null
                          ? '${detail!.avgFramerate!.toStringAsFixed(1)} fps'
                          : '-',
                    ),
                    _detailRow(
                      '평균 RTT',
                      detail?.avgRttMs != null
                          ? '${detail!.avgRttMs} ms'
                          : '-',
                    ),
                    _detailRow(
                      '패킷 손실',
                      detail?.totalPacketsLost != null
                          ? '${detail!.totalPacketsLost}개'
                          : '-',
                    ),
                    _detailRow(
                      '수신 데이터',
                      detail?.totalBytesReceived != null
                          ? '${(detail!.totalBytesReceived! / 1024 / 1024).toStringAsFixed(2)} MB'
                          : '-',
                    ),
                  ],
                ),

                // ── 5. 녹화/PDF 섹션 (항상 표시) ──
                if (detail != null) ...[
                  const SizedBox(height: 12),
                  _buildRecordingSection(ctx, detail),
                ],

                // ── 6. 매크로/플레이북 실행 기록 (있을 때만 표시) ──
                if (macroLogs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _detailSection(
                    title: '매크로 / 플레이북 실행 기록',
                    children: macroLogs
                        .map((log) => _logRow(log))
                        .toList(),
                  ),
                ],

                // ── 7. AI 대화 기록 (있을 때만 표시) ──
                if (aiLogs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _detailSection(
                    title: 'AI 대화 기록',
                    children:
                        aiLogs.map((log) => _logRow(log)).toList(),
                  ),
                ],

                // ── 8. 감사 로그 (진단/복구 승인 이력) ──
                if (auditLogs.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _detailSection(
                    title: '감사 로그 (승인/실행 이력)',
                    children: auditLogs.map((log) => _auditRow(log)).toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기', style: TextStyle(color: accent)),
          ),
        ],
      ),
    );
  }

  // 상세 모달의 섹션 컨테이너 (제목 + 내용 목록)
  Widget _detailSection({
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgSecondary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 섹션 제목
          Text(
            title,
            style: const TextStyle(
              color: accent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  // 상세 모달의 라벨-값 행 위젯
  Widget _detailRow(String label, String? value, {int maxLines = 1, bool isUrl = false}) {
    final displayValue = (value == null || value.isEmpty) ? '-' : value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 레이블: 고정 너비로 정렬
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: textSecondary, fontSize: 12),
            ),
          ),
          // 값: URL이면 강조 색상 적용
          Expanded(
            child: Text(
              displayValue,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isUrl ? accent : textPrimary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 녹화/PDF 섹션 위젯 (다운로드, 스트리밍, PDF 생성 버튼 포함)
  Widget _buildRecordingSection(BuildContext ctx, SessionDetail detail) {
    final hasRecording = detail.recordingUrl != null;
    final hasPdf = detail.pdfUrl != null;

    return _detailSection(
      title: '녹화 / 요약',
      children: [
        if (hasRecording) ...[
          // 녹화 파일 로컬 다운로드
          _actionButton(
            icon: Icons.download,
            label: '녹화 다운로드 (파일 저장)',
            onTap: () => _downloadRecording(ctx, detail.recordingUrl!),
          ),
          const SizedBox(height: 6),
          // 녹화 스트리밍 재생 (브라우저)
          _actionButton(
            icon: Icons.play_circle_outline,
            label: '녹화 스트리밍 재생',
            onTap: () => _openUrl('$_signalingServerUrl${detail.recordingUrl}'),
          ),
          const SizedBox(height: 6),
        ] else ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '녹화 파일 없음',
              style: TextStyle(color: textSecondary, fontSize: 11),
            ),
          ),
        ],
        if (hasPdf)
          _actionButton(
            icon: Icons.picture_as_pdf,
            label: 'PDF 요약 다운로드',
            color: success,
            onTap: () => _openUrl('$_signalingServerUrl${detail.pdfUrl}'),
          ),
        // 녹화파일이 있고 PDF가 없을 때만 AI 요약 생성 버튼 표시
        if (hasRecording && !hasPdf)
          _buildSummarizeButton(ctx, detail.id),
      ],
    );
  }

  // PDF 요약 생성 버튼 (StatefulBuilder로 로딩 상태 관리)
  Widget _buildSummarizeButton(BuildContext ctx, String sessionId) {
    bool loading = false;
    String? resultPdfUrl;
    String? errorMsg;

    return StatefulBuilder(
      builder: (ctx, setLocalState) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 6),
            _actionButton(
              icon: loading ? Icons.hourglass_top : Icons.auto_awesome,
              label: loading
                  ? 'AI 요약 생성 중...'
                  : (resultPdfUrl != null ? '생성 완료!' : 'AI 요약 PDF 생성'),
              color: loading ? textSecondary : accent,
              onTap: loading
                  ? null
                  : () async {
                      setLocalState(() {
                        loading = true;
                        errorMsg = null;
                      });
                      try {
                        final res = await http.post(
                          Uri.parse('$_signalingServerUrl/api/summarize-session'),
                          headers: {'Content-Type': 'application/json'},
                          body: '{"sessionId":"$sessionId"}',
                        );
                        if (res.statusCode == 200) {
                          final match = RegExp(r'"pdfUrl"\s*:\s*"([^"]+)"')
                              .firstMatch(res.body);
                          if (match != null) {
                            resultPdfUrl = match.group(1);
                            setLocalState(() => loading = false);
                            _openUrl('$_signalingServerUrl$resultPdfUrl');
                          }
                        } else {
                          setLocalState(() {
                            loading = false;
                            errorMsg = '생성 실패: ${res.statusCode}';
                          });
                        }
                      } catch (e) {
                        setLocalState(() {
                          loading = false;
                          errorMsg = '오류: $e';
                        });
                      }
                    },
            ),
            if (errorMsg != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(errorMsg!,
                    style: const TextStyle(color: danger, fontSize: 10)),
              ),
          ],
        );
      },
    );
  }

  // 액션 버튼 위젯 (아이콘 + 라벨)
  Widget _actionButton({
    required IconData icon,
    required String label,
    Color color = accent,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // URL을 브라우저에서 열기
  // 녹화 파일을 로컬 다운로드 폴더에 저장
  Future<void> _downloadRecording(BuildContext ctx, String recordingPath) async {
    final fullUrl = '$_signalingServerUrl$recordingPath';
    final filename = recordingPath.split('/').last;

    // 다운로드 중 스낵바 표시
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('다운로드 중: $filename'),
          backgroundColor: bgCard,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    try {
      final response = await http.get(Uri.parse(fullUrl));
      if (response.statusCode == 200) {
        // 다운로드 폴더에 저장
        final dir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(response.bodyBytes);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('저장 완료: ${file.path}'),
              backgroundColor: bgCard,
              duration: const Duration(seconds: 4),
              action: SnackBarAction(
                label: '폴더 열기',
                textColor: accent,
                onPressed: () => _openUrl(dir.path),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('다운로드 실패: $e'),
            backgroundColor: danger,
          ),
        );
      }
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // 어시스턴트 로그 한 줄 위젯 (역할 배지 + 내용 + 시간)
  // 감사 로그 한 줄 위젯 (actor + action + 시각)
  Widget _auditRow(Map<String, dynamic> log) {
    final actorType = log['actor_type']?.toString() ?? '?';
    final actorId = log['actor_id']?.toString() ?? '';
    final actionType = log['action_type']?.toString() ?? '';
    final createdAt = DateTime.tryParse(log['created_at']?.toString() ?? '') ?? DateTime.now();
    final local = createdAt.toLocal();
    final timeStr =
        '${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';

    // actor_type별 색상 구분
    final actorColor = switch (actorType) {
      'viewer' => accent,
      'host' => warning,
      'server' => textSecondary,
      _ => textSecondary,
    };

    // action_type별 라벨
    String actionLabel = switch (actionType) {
      'issue_detected' => '🚨 이슈 감지',
      'approval_granted' => '✅ 승인 발급',
      'approve_diagnostic' => '🔍 진단 승인',
      'approve_recovery' => '🛠 복구 승인',
      _ => actionType,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // actor_type 배지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: actorColor.withAlpha(40),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(actorType,
                style: TextStyle(color: actorColor, fontSize: 10, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 6),
          // action + actor_id
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(actionLabel,
                    style: const TextStyle(color: textPrimary, fontSize: 12)),
                if (actorId.isNotEmpty)
                  Text(actorId,
                      style: const TextStyle(color: textSecondary, fontSize: 10)),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(timeStr,
              style: const TextStyle(color: textSecondary, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _logRow(AssistantLog log) {
    final isUser = log.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 역할 배지
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: isUser
                  ? accent.withOpacity(0.15)
                  : success.withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isUser ? '고객' : 'AI',
              style: TextStyle(
                color: isUser ? accent : success,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 내용
          Expanded(
            child: Text(
              log.content,
              style: const TextStyle(color: textPrimary, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          // 시간
          Text(
            '${log.createdAt.hour.toString().padLeft(2, '0')}:${log.createdAt.minute.toString().padLeft(2, '0')}',
            style:
                const TextStyle(color: textSecondary, fontSize: 10),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  // 매크로 관리 섹션
  // ──────────────────────────────────────────────

  // OS 값에 해당하는 이모지를 반환
  String _osEmoji(String os) {
    switch (os) {
      case 'win32':
        return '🪟';
      case 'darwin':
        return '🍎';
      case 'linux':
        return '🐧';
      default:
        return '🌐'; // all
    }
  }

  // 카테고리 값에 해당하는 한국어 레이블을 반환
  String _categoryLabel(String category) {
    const labels = {
      'network': '네트워크',
      'process': '프로세스/서비스',
      'cleanup': '시스템 정리',
      'diagnostic': '진단/로그',
      'security': '보안/정책',
      'system': '시스템 제어',
      'general': '일반',
    };
    return labels[category] ?? category;
  }

  Widget _buildMacroSection() {
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 섹션 헤더: 제목 + 추가 버튼
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '매크로 관리',
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _showMacroDialog(null),
                  icon: const Icon(Icons.add, size: 14, color: accent),
                  label: const Text('+ 추가',
                      style: TextStyle(color: accent, fontSize: 12)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: borderColor, height: 1),
          if (_macros.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: Text(
                  '등록된 매크로가 없습니다.',
                  style: TextStyle(color: textSecondary, fontSize: 13),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _macros.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: borderColor, height: 1),
              itemBuilder: (_, i) => _buildMacroRow(_macros[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildMacroRow(MacroItem macro) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // OS 이모지
          Text(_osEmoji(macro.os),
              style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          // 이름 + 카테고리 라벨
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  macro.name,
                  style: const TextStyle(
                      color: textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // 카테고리 배지
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: bgSecondary,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: borderColor),
                  ),
                  child: Text(
                    _categoryLabel(macro.category),
                    style: const TextStyle(
                        color: textSecondary, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          // 수정 버튼
          IconButton(
            icon: const Icon(Icons.edit_outlined,
                size: 16, color: textSecondary),
            tooltip: '수정',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _showMacroDialog(macro),
          ),
          // 삭제 버튼
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 16, color: danger),
            tooltip: '삭제',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _confirmDeleteMacro(macro),
          ),
        ],
      ),
    );
  }

  // 매크로 추가/수정 모달 다이얼로그
  Future<void> _showMacroDialog(MacroItem? existing) async {
    // 기존 값이 있으면 채우고, 없으면 기본값으로 초기화
    final nameCtrl =
        TextEditingController(text: existing?.name ?? '');
    final descCtrl =
        TextEditingController(text: existing?.description ?? '');
    final cmdCtrl =
        TextEditingController(text: existing?.command ?? '');
    String category = existing?.category ?? 'general';
    String commandType = existing?.commandType ?? 'cmd';
    String os = existing?.os ?? 'all';
    bool requiresAdmin = existing?.requiresAdmin ?? false;
    bool isDangerous = existing?.isDangerous ?? false;

    final isEdit = existing != null;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: bgCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              title: Text(
                isEdit ? '매크로 수정' : '매크로 추가',
                style: const TextStyle(
                    color: textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 이름 입력
                      _dialogLabel('이름'),
                      _dialogTextField(nameCtrl, '매크로 이름'),
                      const SizedBox(height: 12),
                      // 설명 입력
                      _dialogLabel('설명'),
                      _dialogTextField(descCtrl, '간단한 설명'),
                      const SizedBox(height: 12),
                      // 카테고리 선택
                      _dialogLabel('카테고리'),
                      _dialogDropdown<String>(
                        value: category,
                        items: const {
                          'network': '네트워크',
                          'process': '프로세스/서비스',
                          'cleanup': '시스템 정리',
                          'diagnostic': '진단/로그',
                          'security': '보안/정책',
                          'system': '시스템 제어',
                          'general': '일반',
                        },
                        onChanged: (v) =>
                            setDialogState(() => category = v!),
                      ),
                      const SizedBox(height: 12),
                      // 명령 타입 선택
                      _dialogLabel('명령 타입'),
                      _dialogDropdown<String>(
                        value: commandType,
                        items: const {
                          'cmd': 'cmd',
                          'powershell': 'powershell',
                          'shell': 'shell',
                        },
                        onChanged: (v) =>
                            setDialogState(() => commandType = v!),
                      ),
                      const SizedBox(height: 12),
                      // 명령어 입력 (여러 줄)
                      _dialogLabel('명령어'),
                      _dialogTextField(cmdCtrl, '실행할 명령어',
                          maxLines: 4),
                      const SizedBox(height: 12),
                      // OS 선택
                      _dialogLabel('지원 OS'),
                      _dialogDropdown<String>(
                        value: os,
                        items: const {
                          'all': '전체 (🌐)',
                          'win32': 'Windows (🪟)',
                          'darwin': 'macOS (🍎)',
                          'linux': 'Linux (🐧)',
                        },
                        onChanged: (v) =>
                            setDialogState(() => os = v!),
                      ),
                      const SizedBox(height: 8),
                      // 관리자 권한 체크박스
                      _dialogCheckbox(
                        label: '관리자 권한 필요',
                        value: requiresAdmin,
                        onChanged: (v) =>
                            setDialogState(() => requiresAdmin = v!),
                      ),
                      // 위험 명령 체크박스
                      _dialogCheckbox(
                        label: '위험 명령어',
                        value: isDangerous,
                        onChanged: (v) =>
                            setDialogState(() => isDangerous = v!),
                        activeColor: danger,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('취소',
                      style: TextStyle(color: textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: accent),
                  onPressed: () async {
                    final data = {
                      'name': nameCtrl.text.trim(),
                      'description': descCtrl.text.trim(),
                      'category': category,
                      'command_type': commandType,
                      'command': cmdCtrl.text.trim(),
                      'os': os,
                      'requires_admin': requiresAdmin,
                      'is_dangerous': isDangerous,
                      'enabled': true,
                      'sort_order': 0,
                    };
                    if (isEdit) {
                      await _svc.updateMacro(existing.id, data);
                    } else {
                      await _svc.createMacro(data);
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    // 저장 후 목록 새로고침
                    _refreshMacros();
                  },
                  child: Text(isEdit ? '저장' : '추가',
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // 매크로 삭제 확인 다이얼로그
  Future<void> _confirmDeleteMacro(MacroItem macro) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('매크로 삭제',
            style: TextStyle(
                color: textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: Text(
          '"${macro.name}" 매크로를 삭제하시겠습니까?',
          style: const TextStyle(color: textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소',
                style: TextStyle(color: textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _svc.deleteMacro(macro.id);
      _refreshMacros();
    }
  }

  // 매크로 목록만 다시 불러와서 상태 갱신
  Future<void> _refreshMacros() async {
    final macros = await _svc.fetchAllMacros();
    if (mounted) setState(() => _macros = macros);
  }

  // ──────────────────────────────────────────────
  // 플레이북 관리 섹션
  // ──────────────────────────────────────────────

  Widget _buildPlaybookSection() {
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 섹션 헤더: 제목 + 추가 버튼
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '플레이북 관리',
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _showPlaybookDialog(null),
                  icon: const Icon(Icons.add, size: 14, color: accent),
                  label: const Text('+ 추가',
                      style: TextStyle(color: accent, fontSize: 12)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: borderColor, height: 1),
          if (_playbooks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: Text(
                  '등록된 플레이북이 없습니다.',
                  style: TextStyle(color: textSecondary, fontSize: 13),
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _playbooks.length,
              separatorBuilder: (_, __) =>
                  const Divider(color: borderColor, height: 1),
              itemBuilder: (_, i) => _buildPlaybookRow(_playbooks[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildPlaybookRow(PlaybookItem playbook) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // 이름 + 설명
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  playbook.name,
                  style: const TextStyle(
                      color: textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                if (playbook.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    playbook.description,
                    style: const TextStyle(
                        color: textSecondary, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // 단계 수 배지
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: accent.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${playbook.steps.length}단계',
              style:
                  const TextStyle(color: accent, fontSize: 11),
            ),
          ),
          const SizedBox(width: 4),
          // 수정 버튼
          IconButton(
            icon: const Icon(Icons.edit_outlined,
                size: 16, color: textSecondary),
            tooltip: '수정',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _showPlaybookDialog(playbook),
          ),
          // 삭제 버튼
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 16, color: danger),
            tooltip: '삭제',
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _confirmDeletePlaybook(playbook),
          ),
        ],
      ),
    );
  }

  // 플레이북 추가/수정 모달 다이얼로그
  Future<void> _showPlaybookDialog(PlaybookItem? existing) async {
    final nameCtrl =
        TextEditingController(text: existing?.name ?? '');
    final descCtrl =
        TextEditingController(text: existing?.description ?? '');

    // 기존 steps를 JSON 문자열로 변환하여 편집 필드에 채움
    final stepsCtrl = TextEditingController(
      text: existing != null
          ? jsonEncode(existing.steps
              .map((s) => {
                    'name': s.name,
                    'command': s.command,
                    'command_type': s.commandType,
                    if (s.validateContains != null)
                      'validate_contains': s.validateContains,
                  })
              .toList())
          : '',
    );

    final isEdit = existing != null;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: bgCard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              title: Text(
                isEdit ? '플레이북 수정' : '플레이북 추가',
                style: const TextStyle(
                    color: textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 이름 입력
                      _dialogLabel('이름'),
                      _dialogTextField(nameCtrl, '플레이북 이름'),
                      const SizedBox(height: 12),
                      // 설명 입력
                      _dialogLabel('설명'),
                      _dialogTextField(descCtrl, '간단한 설명'),
                      const SizedBox(height: 12),
                      // 단계 JSON 입력
                      _dialogLabel('단계 (JSON)'),
                      _dialogTextField(
                        stepsCtrl,
                        '[{"name":"단계명","command":"명령어","command_type":"cmd"}]',
                        maxLines: 6,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '각 단계: name, command, command_type 필수.\n'
                        'command_type: cmd / powershell / shell',
                        style:
                            TextStyle(color: textSecondary, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('취소',
                      style: TextStyle(color: textSecondary)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: accent),
                  onPressed: () async {
                    // JSON 파싱 실패 시 오류 메시지 표시
                    List<dynamic> steps;
                    try {
                      steps = jsonDecode(stepsCtrl.text.trim()) as List;
                    } catch (_) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('단계 JSON 형식이 올바르지 않습니다.'),
                          backgroundColor: danger,
                        ),
                      );
                      return;
                    }

                    final data = {
                      'name': nameCtrl.text.trim(),
                      'description': descCtrl.text.trim(),
                      'steps': steps,
                      'enabled': true,
                      'sort_order': 0,
                    };
                    if (isEdit) {
                      await _svc.updatePlaybook(existing.id, data);
                    } else {
                      await _svc.createPlaybook(data);
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    // 저장 후 목록 새로고침
                    _refreshPlaybooks();
                  },
                  child: Text(isEdit ? '저장' : '추가',
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // 플레이북 삭제 확인 다이얼로그
  Future<void> _confirmDeletePlaybook(PlaybookItem playbook) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('플레이북 삭제',
            style: TextStyle(
                color: textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        content: Text(
          '"${playbook.name}" 플레이북을 삭제하시겠습니까?',
          style: const TextStyle(color: textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소',
                style: TextStyle(color: textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _svc.deletePlaybook(playbook.id);
      _refreshPlaybooks();
    }
  }

  // 플레이북 목록만 다시 불러와서 상태 갱신
  Future<void> _refreshPlaybooks() async {
    final playbooks = await _svc.fetchAllPlaybooks();
    if (mounted) setState(() => _playbooks = playbooks);
  }

  // ──────────────────────────────────────────────
  // 다이얼로그 공통 위젯 헬퍼
  // ──────────────────────────────────────────────

  // 입력 필드 레이블
  Widget _dialogLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text,
          style: const TextStyle(color: textSecondary, fontSize: 12)),
    );
  }

  // 다크 테마 텍스트 입력 필드
  Widget _dialogTextField(
    TextEditingController ctrl,
    String hint, {
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      maxLines: maxLines,
      style: const TextStyle(color: textPrimary, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: textSecondary, fontSize: 12),
        filled: true,
        fillColor: bgSecondary,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: accent),
        ),
      ),
    );
  }

  // 다크 테마 드롭다운 선택 필드
  Widget _dialogDropdown<T>({
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: bgSecondary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor),
      ),
      child: DropdownButton<T>(
        value: value,
        isExpanded: true,
        underline: const SizedBox(),
        dropdownColor: bgSecondary,
        style: const TextStyle(color: textPrimary, fontSize: 13),
        items: items.entries
            .map((e) => DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(e.value),
                ))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  // 체크박스 행 (레이블 + Checkbox)
  Widget _dialogCheckbox({
    required String label,
    required bool value,
    required ValueChanged<bool?> onChanged,
    Color activeColor = accent,
  }) {
    return Row(
      children: [
        Checkbox(
          value: value,
          activeColor: activeColor,
          onChanged: onChanged,
        ),
        Text(label,
            style: const TextStyle(color: textPrimary, fontSize: 13)),
      ],
    );
  }
}
