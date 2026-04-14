import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../app_theme.dart';
import '../peer_connection.dart';
import '../signaling.dart';
import '../services/supabase_service.dart';
import '../services/assistant_service.dart';
import '../services/auto_diagnosis.dart';
import '../services/issue_service.dart';
import '../services/chat_service.dart';

// ──────────────────────────────────────────────────────────────
// 채팅 메시지 모델
// ──────────────────────────────────────────────────────────────
class _ChatMessage {
  final String text;
  final bool isUser;
  // 시스템 메시지 (이탤릭 + 작은 글씨로 표시)
  final bool isSystem;
  // 매크로/플레이북 목록 등 커스텀 위젯이 필요한 경우 사용
  final Widget? actionWidget;

  const _ChatMessage({
    required this.text,
    required this.isUser,
    this.isSystem = false,
    this.actionWidget,
  });
}

// 매크로 실행 결과 모델
class MacroResult {
  final bool success;
  final String output;
  final String? error;

  const MacroResult({
    required this.success,
    required this.output,
    this.error,
  });
}

// ──────────────────────────────────────────────────────────────
// 카테고리 한글 라벨 매핑
// ──────────────────────────────────────────────────────────────
const _categoryLabels = {
  'network': '네트워크',
  'process': '프로세스/서비스',
  'cleanup': '시스템 정리',
  'diagnostic': '진단/로그',
  'security': '보안/정책',
  'system': '시스템 제어',
  'general': '일반',
};

// OS 아이콘 매핑
const _osIcons = {
  'win32': '🪟',
  'darwin': '🍎',
  'linux': '🐧',
  'all': '🌐',
};

// ──────────────────────────────────────────────────────────────
// StreamingScreen 위젯
// ──────────────────────────────────────────────────────────────
class StreamingScreen extends StatefulWidget {
  final String serverUrl;
  final String roomId;
  final String viewerId;
  final ViewerSignaling signaling;

  const StreamingScreen({
    super.key,
    required this.serverUrl,
    required this.roomId,
    required this.viewerId,
    required this.signaling,
  });

  @override
  State<StreamingScreen> createState() => _StreamingScreenState();
}

class _StreamingScreenState extends State<StreamingScreen> {
  final _pc = ViewerPeerConnection();
  final _remoteRenderer = RTCVideoRenderer();

  RTCPeerConnectionState _connState =
      RTCPeerConnectionState.RTCPeerConnectionStateNew;

  // 호스트 기본 정보
  String _osInfo = '';
  int _cpuUsage = 0;
  int _memUsed = 0;
  int _memTotal = 0;

  // 화면 소스 목록
  List<Map<String, dynamic>> _sources = [];
  String _activeSourceId = '';

  // 입력 캡처용 렌더 영역
  final GlobalKey _videoKey = GlobalKey();
  Size _renderSize = Size.zero;
  Offset _renderOffset = Offset.zero;

  // AI 어시스턴트 패널
  bool _assistantOpen = false;
  final _assistantController = TextEditingController();
  final List<_ChatMessage> _chatMessages = [];
  bool _assistantLoading = false;
  late final AssistantService _assistantService;

  // 자동 진단
  final _autoDiagnosis = AutoDiagnosis();
  List<DiagnosisResult> _diagResults = [];

  // 호스트 진단 전체 데이터 (상세 패널용)
  Map<String, dynamic>? _lastDiagnostics;
  // 진단 상세 패널 펼침 여부
  bool _diagDetailOpen = false;
  // 호스트 OS 플랫폼 (매크로 필터용: win32 / darwin / linux)
  String _hostPlatform = '';

  // 왼쪽 채팅 위젯 표시 여부 (기본 열림)
  bool _chatOpen = true;

  // 어시스턴트 탭 (0=AI, 1=채팅, 2=매크로, 3=설정)
  int _activeTab = 0;

  // 채팅 탭 상태
  late final ChatService _chatService;

  // 자동진단/복구 이슈 서비스
  late final IssueService _issueService;
  final List<ChatRoomMessage> _chatHistory = [];
  final _chatInputController = TextEditingController();
  bool _chatLoading = false;
  int _unreadCount = 0;
  // 채팅 목록 자동 스크롤용 컨트롤러
  final _chatScrollController = ScrollController();

  // 스레드 패널 상태
  // null이면 일반 채팅 뷰, 값이 있으면 해당 메시지의 스레드 뷰
  ChatRoomMessage? _activeThreadMsg;
  // 현재 열린 스레드의 답글 목록
  final List<ChatRoomMessage> _threadReplies = [];
  // 스레드 답글 입력 컨트롤러
  final _threadInputController = TextEditingController();
  // 스레드 답글 목록 스크롤 컨트롤러
  final _threadScrollController = ScrollController();

  // 매크로/플레이북 목록 (매크로 탭)
  List<MacroItem> _macros = [];
  List<PlaybookItem> _playbooks = [];
  bool _macrosLoading = false;

  // 매크로 실행 대기 맵 (macroId → Completer)
  final Map<String, Completer<MacroResult>> _pendingMacros = {};

  bool _fullscreen = false;
  bool _isRecording = false;

  // 윈도우 전체화면 토글 (실제 최대화/복원)
  Future<void> _toggleFullscreen() async {
    if (_fullscreen) {
      await windowManager.setFullScreen(false);
    } else {
      await windowManager.setFullScreen(true);
    }
    if (mounted) setState(() => _fullscreen = !_fullscreen);
  }

  // autoRecord 설정 확인 후 자동 녹화 시작
  Future<void> _checkAutoRecord() async {
    final prefs = await SharedPreferences.getInstance();
    final autoRecord = prefs.getBool('autoRecord') ?? true;
    if (autoRecord && !_isRecording && mounted) {
      _toggleRecording();
    }
  }

  // 녹화 시작/중단 토글
  // flutter_webrtc Windows는 MediaRecorder를 지원하지 않으므로
  // 상태만 관리하고 DataChannel로 호스트에 알림
  void _toggleRecording() {
    setState(() {
      _isRecording = !_isRecording;
      _chatMessages.add(_ChatMessage(
        text: _isRecording ? '녹화를 시작합니다.' : '녹화를 중단합니다.',
        isUser: false,
      ));
    });
    _pc.sendMessage({'type': 'recording-state', 'recording': _isRecording});
  }

  @override
  void initState() {
    super.initState();
    _assistantService = AssistantService(
      serverUrl: widget.serverUrl
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://'),
    );
    // 채팅 서비스 초기화 (WS 전송은 ViewerSignaling을 통해)
    _chatService = ChatService(
      serverUrl: widget.serverUrl
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://'),
      userId: widget.viewerId,
      userType: 'viewer',
    );
    // 시그널링 WS에서 수신한 채팅 브로드캐스트를 ChatService로 위임
    widget.signaling.onChatMessage = _chatService.handleIncomingWsMessage;

    // 자동진단/복구 이슈 서비스 초기화
    _issueService = IssueService(
      serverUrl: widget.serverUrl
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://'),
    );
    _issueService.onIssuesChanged = () {
      if (mounted) setState(() {});
    };
    // 시그널링 WS의 진단 메시지를 IssueService로 라우팅
    widget.signaling.onDiagnosisMessage = _handleDiagnosisMessage;
    // ChatService가 수신한 메시지를 UI에 반영 (답글/루트 분기 처리)
    _chatService.onMessage = (msg) {
      if (!mounted) return;

      if (msg.parentMessageId != null) {
        // 답글 수신: 부모 메시지의 replyCount를 +1 갱신
        setState(() {
          final idx = _chatHistory.indexWhere((m) => m.id == msg.parentMessageId);
          if (idx >= 0) {
            _chatHistory[idx] = _chatHistory[idx].copyWith(
              replyCount: _chatHistory[idx].replyCount + 1,
            );
          }
          // 스레드 패널이 열려 있고 같은 부모이면 답글 목록에 추가
          if (_activeThreadMsg?.id == msg.parentMessageId) {
            _threadReplies.add(msg);
          }
          // 다른 사람의 답글도 안읽음 합산 (정책: 단순화)
          if (msg.senderId != widget.viewerId && !_chatOpen) _unreadCount++;
        });
        // 스레드 패널이 열려 있으면 자동 스크롤
        if (_activeThreadMsg?.id == msg.parentMessageId) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_threadScrollController.hasClients) {
              _threadScrollController.animateTo(
                _threadScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      } else {
        // 일반 메시지: 메인 채팅에 추가
        setState(() {
          _chatHistory.add(msg);
          if (!_chatOpen) _unreadCount++;
        });
        if (_chatOpen) _scrollChatToBottom();
      }
    };
    _initAndConnect();
  }

  Future<void> _initAndConnect() async {
    await _remoteRenderer.initialize();
    if (!mounted) return;
    _setupSignaling();
    _setupPeerConnection();
  }

  @override
  void dispose() {
    _remoteRenderer.dispose();
    _pc.close();
    _assistantController.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    _threadInputController.dispose();
    _threadScrollController.dispose();
    SupabaseService.instance.endSession('user-disconnect');
    super.dispose();
  }

  // 채팅 탭 진입 시 채팅방 입장 및 이전 메시지 로드
  Future<void> _initChat() async {
    setState(() => _chatLoading = true);
    final sessionId = SupabaseService.instance.activeSessionId ?? '';
    debugPrint('[chat] _initChat: sessionId=$sessionId, viewerId=${widget.viewerId}');
    final roomId = await _chatService.createOrJoinRoom(
      sessionId,
      ['host', widget.viewerId],
    );
    debugPrint('[chat] _initChat: chatRoomId=$roomId');
    if (roomId != null) {
      _chatService.chatRoomId = roomId;
      final messages = await _chatService.loadMessages();
      if (mounted) {
        setState(() => _chatHistory.addAll(messages));
      }
    } else {
      debugPrint('[chat] 채팅방 생성 실패! sessionId가 유효한 UUID인지 확인');
    }
    if (mounted) setState(() => _chatLoading = false);
    // 로드 완료 후 맨 아래로 스크롤
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollChatToBottom());
  }

  // 채팅 목록을 맨 아래로 스크롤
  void _scrollChatToBottom() {
    if (_chatScrollController.hasClients) {
      _chatScrollController.animateTo(
        _chatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  // 스레드 답글 전송
  void _sendThreadReply() {
    final trimmed = _threadInputController.text.trim();
    if (trimmed.isEmpty || _chatService.chatRoomId == null || _activeThreadMsg == null) return;
    _threadInputController.clear();

    widget.signaling.sendChatMessage({
      'type': 'chat-message',
      'chatRoomId': _chatService.chatRoomId!,
      'senderId': widget.viewerId,
      'senderType': 'viewer',
      'content': trimmed,
      'messageType': 'text',
      'parentMessageId': _activeThreadMsg!.id,
    });
  }

  // 스레드 패널 열기: 해당 메시지의 답글 목록을 로드
  void _openThreadPanel(ChatRoomMessage msg) {
    setState(() {
      _activeThreadMsg = msg;
      _threadReplies.clear();
    });
    // 서버에서 답글 로드
    _chatService.loadReplies(msg.id).then((replies) {
      if (!mounted) return;
      setState(() => _threadReplies.addAll(replies));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_threadScrollController.hasClients) {
          _threadScrollController.jumpTo(
            _threadScrollController.position.maxScrollExtent,
          );
        }
      });
    });
  }

  // 스레드 패널 닫기
  void _closeThreadPanel() {
    setState(() {
      _activeThreadMsg = null;
      _threadReplies.clear();
    });
  }

  // 채팅 메시지 전송 (시그널링 WS 통해 서버로 전달)
  void _sendChatMessage(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty || _chatService.chatRoomId == null) return;
    _chatInputController.clear();

    widget.signaling.sendChatMessage({
      'type': 'chat-message',
      'chatRoomId': _chatService.chatRoomId!,
      'senderId': widget.viewerId,
      'senderType': 'viewer',
      'content': trimmed,
      'messageType': 'text',
    });
  }

  // 채팅 탭으로 전환 시 안읽은 수 초기화 + 읽음 처리
  void _onChatTabSelected() {
    setState(() => _unreadCount = 0);
    _chatService.markAsRead();
    // 스크롤 위치를 맨 아래로
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollChatToBottom());
  }

  // ──────────────────────────────────────────────────────────────
  // 시그널링 & P2P 설정
  // ──────────────────────────────────────────────────────────────
  void _setupSignaling() {
    widget.signaling.onAnswer = (sdp) async {
      await _pc.setAnswer(sdp);
    };

    widget.signaling.onIceCandidate = (candidate) async {
      await _pc.addIceCandidate(candidate);
    };

    widget.signaling.onDisconnected = () {
      if (mounted) _showDisconnectDialog('시그널링 서버 연결이 끊어졌습니다.');
    };
  }

  void _setupPeerConnection() {
    _pc.onTrack = (stream) {
      debugPrint(
          '[streaming] onTrack: 비디오 트랙 수신, tracks=${stream.getVideoTracks().length}');
      if (mounted) {
        setState(() => _remoteRenderer.srcObject = stream);
        // 비디오 렌더링 시작 후 bounds를 미리 초기화 (첫 클릭이 무시되는 문제 방지)
        Future.delayed(const Duration(milliseconds: 500), () {
          _updateRenderBounds(force: true);
          _invalidateVideoLayout();
        });
      }
    };

    _pc.onChannelOpen = (_) async {
      // 세션 생성을 먼저 완료한 후 채팅 초기화 (activeSessionId 필요)
      await SupabaseService.instance.startSession(
        widget.roomId,
        widget.viewerId,
      );
      // 호스트에게 Supabase 세션 UUID를 전달 (호스트가 같은 채팅방에 입장하기 위함)
      final sid = SupabaseService.instance.activeSessionId;
      if (sid != null && sid.isNotEmpty) {
        _pc.sendMessage({'type': 'session-info', 'sessionId': sid});
      }
      _checkAutoRecord();
      _initChat();
    };

    _pc.onConnectionState = (state) {
      if (mounted) setState(() => _connState = state);
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _showDisconnectDialog('P2P 연결이 끊어졌습니다.');
      }
    };

    _pc.onControlMessage = (msg) {
      _handleControlMessage(msg);
    };

    _pc.onIceCandidate = (candidate) {
      widget.signaling.sendIceCandidate(
        {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
        widget.viewerId,
      );
    };

    _pc.onOfferReady = (offer) {
      widget.signaling.sendOffer(
        {'type': offer.type, 'sdp': offer.sdp},
        widget.viewerId,
      );
    };

    _pc.startOffer(widget.viewerId);
  }

  // ──────────────────────────────────────────────────────────────
  // DataChannel 메시지 처리
  // ──────────────────────────────────────────────────────────────
  void _handleControlMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    switch (type) {
      case 'host-info':
        final info = msg['info'] as Map<String, dynamic>? ?? {};
        if (mounted) {
          setState(() {
            _osInfo = info['os']?.toString() ?? '';
            _cpuUsage = (info['cpuUsage'] as num?)?.toInt() ?? 0;
            _memUsed = (info['memUsed'] as num?)?.toInt() ?? 0;
            _memTotal = (info['memTotal'] as num?)?.toInt() ?? 0;
          });
        }
        return;

      case 'screen-sources':
        final sources =
            (msg['sources'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        final active = msg['activeSourceId']?.toString() ?? '';
        if (mounted) {
          setState(() {
            _sources = sources;
            _activeSourceId = active;
          });
        }
        return;

      case 'source-changed':
        final sourceId = msg['sourceId']?.toString() ?? '';
        if (mounted) setState(() => _activeSourceId = sourceId);
        return;

      case 'host-diagnostics':
        final diag = msg['diagnostics'] as Map<String, dynamic>?;
        if (diag != null && mounted) {
          // 전체 진단 데이터 보관 (상세 패널용)
          _lastDiagnostics = diag;
          // 호스트 OS 플랫폼 추출 (매크로 필터용)
          final sysOs = diag['system']?['os']?.toString() ?? '';
          if (sysOs.isNotEmpty) _hostPlatform = sysOs;

          setState(() {
            if (diag['system'] != null) {
              var results = _autoDiagnosis.run(diag);
              // P2P 연결 중이면 "인터넷 불가"와 "모니터 감지 불가"는 오탐이므로 제외
              if (_connState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
                results = results.where((r) =>
                    r.title != '인터넷 불가' && r.title != '모니터 감지 불가').toList();
              }
              _diagResults = results;
            }
          });

          // 호스트 정보를 Supabase sessions 테이블에 기록
          SupabaseService.instance.updateHostInfo(
            hostOs: sysOs,
            hostMemTotalMb: (diag['system']?['mem']?['total'] as num?)?.toInt(),
          );
        }
        return;

      case 'macro-result':
        // 매크로 실행 결과 수신 → 대기 중인 Completer에 전달
        final macroId = msg['macroId'] as String? ?? '';
        final success = msg['success'] as bool? ?? false;
        final output = msg['output'] as String? ?? '';
        final error = msg['error'] as String?;
        _resolveMacroResult(macroId, success, output, error);
        return;

      case 'recording-result':
        // 호스트에서 녹화 완료 후 결과 수신
        final success = msg['success'] as bool? ?? false;
        final url = msg['url'] as String?;
        if (success && url != null) {
          SupabaseService.instance.updateRecordingUrl(url);
          if (mounted) {
            setState(() {
              _chatMessages.add(const _ChatMessage(
                text: '녹화 파일이 저장되었습니다.',
                isUser: false,
              ));
            });
          }
        } else {
          final error = msg['error'] as String? ?? '알 수 없는 오류';
          if (mounted) {
            setState(() {
              _chatMessages.add(_ChatMessage(
                text: '녹화 실패: $error',
                isUser: false,
              ));
            });
          }
        }
        return;

      default:
        return;
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 매크로 실행 인프라
  // ──────────────────────────────────────────────────────────────

  // DataChannel로 execute-macro 명령을 전송하고 결과를 기다림 (최대 30초)
  Future<MacroResult> _sendMacroCommand(
    String macroId,
    String command,
    String commandType,
  ) {
    final completer = Completer<MacroResult>();
    _pendingMacros[macroId] = completer;

    _pc.sendMessage({
      'type': 'execute-macro',
      'macroId': macroId,
      'command': command,
      'commandType': commandType,
    });

    // 30초 타임아웃
    Future.delayed(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        _pendingMacros.remove(macroId);
        completer.complete(
          const MacroResult(success: false, output: '', error: '타임아웃: 30초 초과'),
        );
      }
    });

    return completer.future;
  }

  // macro-result 수신 시 Completer를 완료 처리
  void _resolveMacroResult(
    String macroId,
    bool success,
    String output,
    String? error,
  ) {
    final completer = _pendingMacros.remove(macroId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        MacroResult(success: success, output: output, error: error),
      );
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 어시스턴트 입력 처리
  // ──────────────────────────────────────────────────────────────

  Future<void> _sendAssistantQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _assistantController.clear();

    // /macro 명령: 매크로 목록 표시
    if (trimmed == '/macro') {
      setState(() {
        _chatMessages.add(const _ChatMessage(text: '/macro', isUser: true));
      });
      await _showMacroList();
      return;
    }

    // /playbook 명령: 플레이북 목록 표시
    if (trimmed == '/playbook') {
      setState(() {
        _chatMessages.add(const _ChatMessage(text: '/playbook', isUser: true));
      });
      await _showPlaybookList();
      return;
    }

    // 일반 AI 질문
    setState(() {
      _chatMessages.add(_ChatMessage(text: trimmed, isUser: true));
      _assistantLoading = true;
    });

    // 응답 시간 측정
    final sw = Stopwatch()..start();

    // Supabase에 사용자 메시지 로깅
    await SupabaseService.instance.logAssistantMessage(
      'user',
      trimmed,
      query: trimmed,
    );

    final resp = await _assistantService.askAssistant(trimmed);
    sw.stop();

    if (mounted) {
      // source에 따라 접두어 표시
      final prefix =
          resp.source == 'supabase' ? '📄 내부 문서 기반\n\n' : '🤖 AI 답변\n\n';
      final displayText = '$prefix${resp.answer}';

      setState(() {
        _chatMessages.add(_ChatMessage(text: displayText, isUser: false));
        _assistantLoading = false;
      });

      // Supabase에 어시스턴트 응답 로깅
      await SupabaseService.instance.logAssistantMessage(
        'assistant',
        resp.answer,
        source: resp.source,
        query: trimmed,
        docResultsCount: resp.sources.length,
        responseTimeMs: sw.elapsedMilliseconds,
      );
    }
  }

  // /macro 명령 처리: 목록을 채팅에 위젯으로 추가
  Future<void> _showMacroList() async {
    setState(() => _assistantLoading = true);
    final macros = await _assistantService.fetchMacros();
    setState(() => _assistantLoading = false);

    if (!mounted) return;

    // 호스트 플랫폼에 맞는 매크로만 필터 (all은 항상 포함)
    final filtered = macros.where((m) {
      return m.os == 'all' || _hostPlatform.isEmpty || m.os == _hostPlatform;
    }).toList();

    if (filtered.isEmpty) {
      setState(() {
        _chatMessages.add(const _ChatMessage(
          text: '사용 가능한 매크로가 없습니다.',
          isUser: false,
          isSystem: true,
        ));
      });
      return;
    }

    // 매크로 목록 위젯을 채팅 버블로 추가
    setState(() {
      _chatMessages.add(_ChatMessage(
        text: '',
        isUser: false,
        actionWidget: _buildMacroListWidget(filtered),
      ));
    });
  }

  // /playbook 명령 처리: 목록을 채팅에 위젯으로 추가
  Future<void> _showPlaybookList() async {
    setState(() => _assistantLoading = true);
    final playbooks = await _assistantService.fetchPlaybooks();
    setState(() => _assistantLoading = false);

    if (!mounted) return;

    if (playbooks.isEmpty) {
      setState(() {
        _chatMessages.add(const _ChatMessage(
          text: '사용 가능한 플레이북이 없습니다.',
          isUser: false,
          isSystem: true,
        ));
      });
      return;
    }

    setState(() {
      _chatMessages.add(_ChatMessage(
        text: '',
        isUser: false,
        actionWidget: _buildPlaybookListWidget(playbooks),
      ));
    });
  }

  // 매크로 실행 확인 후 DataChannel로 전송
  Future<void> _executeMacro(MacroItem macro) async {
    // 위험 매크로는 추가 확인
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: bgCard,
        title: Text(
          '매크로 실행 확인',
          style: TextStyle(
            color: macro.isDangerous ? danger : textPrimary,
            fontSize: 14,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(macro.name,
                style: const TextStyle(
                    color: textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(macro.description,
                style: const TextStyle(color: textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: bgPrimary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(macro.command,
                  style: const TextStyle(color: textSecondary, fontSize: 11)),
            ),
            if (macro.isDangerous) ...[
              const SizedBox(height: 8),
              const Text('⚠️ 위험한 명령입니다. 신중하게 실행하세요.',
                  style: TextStyle(color: danger, fontSize: 11)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('실행',
                style: TextStyle(color: macro.isDangerous ? danger : accent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // 실행 중 메시지 추가
    setState(() {
      _chatMessages.add(_ChatMessage(
        text: '⏳ [${macro.name}] 실행 중...',
        isUser: false,
        isSystem: true,
      ));
    });

    final result =
        await _sendMacroCommand(macro.id, macro.command, macro.commandType);

    if (!mounted) return;

    // 결과 메시지 추가
    if (result.success) {
      setState(() {
        _chatMessages.add(_ChatMessage(
          text: '✅ [${macro.name}] 성공\n\n${result.output}',
          isUser: false,
        ));
      });
    } else {
      setState(() {
        _chatMessages.add(_ChatMessage(
          text: '❌ [${macro.name}] 실패\n\n${result.error ?? result.output}',
          isUser: false,
        ));
      });
    }
  }

  // 플레이북 단계별 순차 실행
  Future<void> _executePlaybook(PlaybookItem playbook) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: bgCard,
        title: const Text('플레이북 실행 확인',
            style: TextStyle(color: textPrimary, fontSize: 14)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(playbook.name,
                style: const TextStyle(
                    color: textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(playbook.description,
                style: const TextStyle(color: textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            Text('총 ${playbook.steps.length}단계를 순서대로 실행합니다.',
                style: const TextStyle(color: textSecondary, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('실행', style: TextStyle(color: accent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _chatMessages.add(_ChatMessage(
        text: '▶ [${playbook.name}] 플레이북 시작 (${playbook.steps.length}단계)',
        isUser: false,
        isSystem: true,
      ));
    });

    // 각 단계를 순서대로 실행
    for (int i = 0; i < playbook.steps.length; i++) {
      final step = playbook.steps[i];
      final stepLabel = '(${i + 1}/${playbook.steps.length}) ${step.name}';

      if (!mounted) break;

      // 단계 시작 표시
      setState(() {
        _chatMessages.add(_ChatMessage(
          text: '⏳ $stepLabel',
          isUser: false,
          isSystem: true,
        ));
      });

      // macroId 자리에 playbook step 식별자 사용
      final stepId = '${playbook.id}_step_$i';
      final result =
          await _sendMacroCommand(stepId, step.command, step.commandType);

      if (!mounted) break;

      // validateContains 검증
      bool stepSuccess = result.success;
      if (stepSuccess && step.validateContains != null) {
        stepSuccess = result.output.contains(step.validateContains!);
      }

      if (stepSuccess) {
        setState(() {
          _chatMessages.add(_ChatMessage(
            text: '✅ $stepLabel\n${result.output}',
            isUser: false,
          ));
        });
      } else {
        setState(() {
          _chatMessages.add(_ChatMessage(
            text: '❌ $stepLabel 실패 → 플레이북 중단\n${result.error ?? result.output}',
            isUser: false,
          ));
        });
        return; // 실패 시 중단
      }
    }

    if (mounted) {
      setState(() {
        _chatMessages.add(_ChatMessage(
          text: '✅ [${playbook.name}] 플레이북 완료',
          isUser: false,
          isSystem: true,
        ));
      });
    }
  }

  // ──────────────────────────────────────────────────────────────
  // 입력 이벤트 처리
  // ──────────────────────────────────────────────────────────────
  void _updateRenderBounds({bool force = false}) {
    final box = _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final newSize = box.size;
    final newOffset = box.localToGlobal(Offset.zero);
    // 위젯 크기가 변경되면 렌더링 영역 캐시도 무효화
    if (newSize != _renderSize || newOffset != _renderOffset) {
      _renderSize = newSize;
      _renderOffset = newOffset;
      _invalidateVideoLayout();
    }
  }

  // 비디오 렌더링 영역 캐시 (object-fit: contain 보정값)
  double _cachedRenderW = 0, _cachedRenderH = 0;
  double _cachedOffsetX = 0, _cachedOffsetY = 0;
  int _cachedVideoW = 0, _cachedVideoH = 0;
  Size _cachedElSize = Size.zero;

  // 비디오 해상도 또는 위젯 크기 변경 시 호출
  void _invalidateVideoLayout() {
    _cachedElSize = Size.zero; // 다음 _normalizeCoords에서 재계산
  }

  // mousemove throttle — 최대 60fps (약 16ms 간격)
  int _lastMouseSendMs = 0;

  // object-fit: contain 보정 — 캐시된 렌더링 영역으로 좌표 계산
  ({double x, double y})? _normalizeCoords(PointerEvent event) {
    if (_renderSize == Size.zero) return null;

    final vw = _remoteRenderer.videoWidth;
    final vh = _remoteRenderer.videoHeight;
    if (vw == 0 || vh == 0) {
      final localX = event.position.dx - _renderOffset.dx;
      final localY = event.position.dy - _renderOffset.dy;
      return (
        x: (localX / _renderSize.width).clamp(0.0, 1.0),
        y: (localY / _renderSize.height).clamp(0.0, 1.0),
      );
    }

    // 비디오 해상도나 위젯 크기가 변경된 경우에만 재계산
    if (vw != _cachedVideoW || vh != _cachedVideoH || _renderSize != _cachedElSize) {
      _cachedVideoW = vw;
      _cachedVideoH = vh;
      _cachedElSize = _renderSize;

      final elW = _renderSize.width;
      final elH = _renderSize.height;
      final vidRatio = vw.toDouble() / vh.toDouble();

      if (vidRatio > elW / elH) {
        _cachedRenderW = elW;
        _cachedRenderH = elW / vidRatio;
        _cachedOffsetX = 0;
        _cachedOffsetY = (elH - _cachedRenderH) / 2;
      } else {
        _cachedRenderH = elH;
        _cachedRenderW = elH * vidRatio;
        _cachedOffsetX = (elW - _cachedRenderW) / 2;
        _cachedOffsetY = 0;
      }
    }

    final localX = event.position.dx - _renderOffset.dx;
    final localY = event.position.dy - _renderOffset.dy;
    final nx = (localX - _cachedOffsetX) / _cachedRenderW;
    final ny = (localY - _cachedOffsetY) / _cachedRenderH;

    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null;
    return (x: nx, y: ny);
  }

  void _onPointerMove(PointerEvent event) {
    // 16ms 간격 throttle (최대 ~60fps)
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastMouseSendMs < 16) return;
    _lastMouseSendMs = now;

    _updateRenderBounds();
    final coords = _normalizeCoords(event);
    if (coords == null) return;
    _pc.sendMessage({'type': 'mousemove', 'x': coords.x, 'y': coords.y});
  }

  void _onPointerDown(PointerEvent event) {
    _updateRenderBounds(force: true);
    // 첫 클릭 시에도 좌표가 정확하도록 클릭 전 mousemove를 먼저 전송
    final coords = _normalizeCoords(event);
    if (coords == null) return;
    _pc.sendMessage({'type': 'mousemove', 'x': coords.x, 'y': coords.y});
    _pc.sendMessage(
        {'type': 'mousedown', 'button': 0, 'x': coords.x, 'y': coords.y});
  }

  void _onPointerUp(PointerEvent event) {
    _updateRenderBounds(force: true);
    final coords = _normalizeCoords(event);
    if (coords == null) return;
    _pc.sendMessage(
        {'type': 'mouseup', 'button': 0, 'x': coords.x, 'y': coords.y});
  }

  int _lastScrollSendMs = 0;

  void _onScroll(PointerScrollEvent event) {
    // 16ms throttle — 초당 최대 60회로 스크롤 이벤트 제한
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastScrollSendMs < 16) return;
    _lastScrollSendMs = now;

    _pc.sendMessage({
      'type': 'scroll',
      'deltaX': event.scrollDelta.dx,
      'deltaY': event.scrollDelta.dy,
    });
  }

  void _switchSource(String sourceId) {
    _pc.sendMessage({'type': 'switch-source', 'sourceId': sourceId});
    setState(() => _activeSourceId = sourceId);
    // 모니터 전환 후 비디오 해상도 변경 → 캐시 무효화 + bounds 갱신
    _invalidateVideoLayout();
    Future.delayed(const Duration(milliseconds: 300), () {
      _updateRenderBounds(force: true);
      _invalidateVideoLayout();
    });
  }

  // 연결 종료 확인 팝업
  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('연결 종료',
            style: TextStyle(
                color: textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text('상담 연결을 종료하시겠습니까?',
            style: TextStyle(color: textSecondary, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소', style: TextStyle(color: textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('종료', style: TextStyle(color: danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) _disconnect();
  }

  void _disconnect() {
    if (_isRecording) {
      _pc.sendMessage({'type': 'recording-state', 'recording': false});
      _isRecording = false;
    }
    widget.signaling.disconnect();
    _pc.close();
    Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
  }

  void _showDisconnectDialog(String reason) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: bgCard,
        title: const Text('연결 종료', style: TextStyle(color: textPrimary)),
        content: Text(reason, style: const TextStyle(color: textSecondary)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _disconnect();
            },
            child: const Text('확인', style: TextStyle(color: accent)),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 빌드
  // ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgPrimary,
      body: Column(
        children: [
          _buildStatusBar(),
          Expanded(
            child: Row(
              children: [
                // 왼쪽: 채팅 위젯 (접기 가능)
                if (_chatOpen) _buildChatWidget(),
                // 가운데: 비디오
                Expanded(child: _buildVideoArea()),
                // 오른쪽: AI 어시스턴트
                if (_assistantOpen) _buildAssistantPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 상태 바
  // ──────────────────────────────────────────────────────────────
  Widget _buildStatusBar() {
    final (stateLabel, stateColor) = switch (_connState) {
      RTCPeerConnectionState.RTCPeerConnectionStateConnected => (
          '연결됨',
          success
        ),
      RTCPeerConnectionState.RTCPeerConnectionStateConnecting => (
          '연결 중',
          warning
        ),
      RTCPeerConnectionState.RTCPeerConnectionStateFailed => ('실패', danger),
      RTCPeerConnectionState.RTCPeerConnectionStateDisconnected => (
          '끊김',
          danger
        ),
      _ => ('대기', textSecondary),
    };

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: bgSecondary,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: stateColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(stateLabel, style: TextStyle(color: stateColor, fontSize: 12)),
          if (_osInfo.isNotEmpty) ...[
            const SizedBox(width: 16),
            Text(_osInfo,
                style: const TextStyle(color: textSecondary, fontSize: 12)),
          ],
          if (_memTotal > 0) ...[
            const SizedBox(width: 12),
            Text(
              'CPU: $_cpuUsage%  MEM: $_memUsed/$_memTotal MB',
              style: const TextStyle(color: textSecondary, fontSize: 12),
            ),
          ],
          const Spacer(),
          // 모니터 전환 버튼
          ..._sources.map(
            (src) => Padding(
              padding: const EdgeInsets.only(left: 4),
              child: _buildMonitorButton(src),
            ),
          ),
          const SizedBox(width: 8),
          // 채팅 열기 버튼 (채팅 위젯이 닫혀 있을 때만 표시)
          if (!_chatOpen) ...[
            _buildIconBtn(
              icon: Icons.chat_bubble_outline,
              tooltip: '채팅 열기',
              active: false,
              onTap: () => setState(() {
                _chatOpen = true;
                _unreadCount = 0;
              }),
            ),
            if (_unreadCount > 0)
              Container(
                width: 16,
                height: 16,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: danger,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    '$_unreadCount',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            const SizedBox(width: 4),
          ],
          // AI 어시스턴트 토글
          _buildIconBtn(
            icon: Icons.smart_toy_outlined,
            tooltip: 'AI 어시스턴트',
            active: _assistantOpen,
            onTap: () => setState(() => _assistantOpen = !_assistantOpen),
          ),
          const SizedBox(width: 4),
          // 녹화 버튼
          _buildIconBtn(
            icon: _isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
            tooltip: _isRecording ? '녹화 중단' : '녹화 시작',
            color: _isRecording ? danger : textSecondary,
            onTap: _toggleRecording,
          ),
          const SizedBox(width: 4),
          // 전체화면 토글 (실제 윈도우 최대화/복원)
          _buildIconBtn(
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            tooltip: _fullscreen ? '전체화면 해제' : '전체화면',
            onTap: _toggleFullscreen,
          ),
          const SizedBox(width: 4),
          // 연결 종료 (확인 팝업)
          _buildIconBtn(
            icon: Icons.stop_circle_outlined,
            tooltip: '연결 종료',
            color: danger,
            onTap: _confirmDisconnect,
          ),
        ],
      ),
    );
  }

  Widget _buildMonitorButton(Map<String, dynamic> src) {
    final id = src['id']?.toString() ?? '';
    final name = src['name']?.toString() ?? 'Monitor';
    final isActive = id == _activeSourceId;
    return GestureDetector(
      onTap: () => _switchSource(id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? accent.withAlpha(40) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isActive ? accent : borderColor),
        ),
        child: Text(
          name,
          style: TextStyle(
            color: isActive ? accent : textSecondary,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  Widget _buildIconBtn({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    Color color = textSecondary,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: active ? accent.withAlpha(40) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, color: active ? accent : color, size: 16),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 왼쪽 채팅 위젯
  // ──────────────────────────────────────────────────────────────
  Widget _buildChatWidget() {
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: bgSecondary,
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: Column(
        children: [
          // 헤더: 스레드 모드면 "← 채팅" 버튼, 아니면 일반 타이틀
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                if (_activeThreadMsg != null) ...[
                  // 스레드 패널 헤더: 뒤로 가기 버튼
                  GestureDetector(
                    onTap: _closeThreadPanel,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_back_ios, size: 12, color: accent),
                        SizedBox(width: 2),
                        Text('채팅', style: TextStyle(color: accent, fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '스레드',
                    style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ] else ...[
                  // 일반 채팅 헤더
                  const Text(
                    '채팅',
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_unreadCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: danger,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        '$_unreadCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ],
                ],
                const Spacer(),
                // 채팅 패널 접기 (스레드 모드에서도 가능)
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 16, color: textSecondary),
                  onPressed: () => setState(() => _chatOpen = false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
              ],
            ),
          ),
          // 스레드 패널 or 일반 채팅 탭
          Expanded(
            child: _activeThreadMsg != null
                ? _buildThreadPanel()
                : _buildChatTab(),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 스레드 패널 (부모 메시지 + 답글 목록 + 답글 입력)
  // ──────────────────────────────────────────────────────────────
  Widget _buildThreadPanel() {
    final parent = _activeThreadMsg!;
    final timeStr =
        '${parent.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${parent.createdAt.toLocal().minute.toString().padLeft(2, '0')}';

    return Column(
      children: [
        // 원본 메시지 블록
        Container(
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 발신자 + 시간
              Text(
                '${parent.senderType == 'host' ? '호스트' : '뷰어'} · $timeStr',
                style: const TextStyle(color: textSecondary, fontSize: 10),
              ),
              const SizedBox(height: 4),
              SelectableText(
                parent.content,
                style: const TextStyle(color: textPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
        // 답글 수 구분선
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Expanded(child: Divider(color: borderColor, height: 1)),
              const SizedBox(width: 8),
              Text(
                _threadReplies.isEmpty ? '아직 답글이 없습니다' : '답글 ${_threadReplies.length}개',
                style: const TextStyle(color: textSecondary, fontSize: 10),
              ),
              const SizedBox(width: 8),
              const Expanded(child: Divider(color: borderColor, height: 1)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // 답글 목록
        Expanded(
          child: ListView.builder(
            controller: _threadScrollController,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            itemCount: _threadReplies.length,
            // 스레드 안에서는 답글 배지/버튼 없이 렌더링
            itemBuilder: (_, i) => _buildChatBubble(_threadReplies[i], isThreadView: true),
          ),
        ),
        // 답글 입력 바
        _buildThreadInput(),
      ],
    );
  }

  // 스레드 답글 입력 바
  Widget _buildThreadInput() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _threadInputController,
              style: const TextStyle(color: textPrimary, fontSize: 12),
              decoration: InputDecoration(
                hintText: '답글 입력...',
                hintStyle: const TextStyle(color: textSecondary, fontSize: 11),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: accent),
                ),
                filled: true,
                fillColor: bgCard,
              ),
              onSubmitted: (_) => _sendThreadReply(),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendThreadReply,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 14),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 비디오 영역
  // ──────────────────────────────────────────────────────────────
  Widget _buildVideoArea() {
    return Stack(
      children: [
        // 비디오 렌더링
        Positioned.fill(
          child: Container(
            color: Colors.black,
            child: RTCVideoView(
              key: _videoKey,
              _remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
        // 투명 오버레이로 모든 포인터 이벤트를 캡처
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerMove: _onPointerMove,
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) _onScroll(event);
            },
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 어시스턴트 패널 (메인 컨테이너)
  // ──────────────────────────────────────────────────────────────
  Widget _buildAssistantPanel() {
    return Container(
      width: 360,
      decoration: const BoxDecoration(
        color: bgSecondary,
        border: Border(left: BorderSide(color: borderColor)),
      ),
      child: Column(
        children: [
          _buildAssistantHeader(),
          // 호스트 시스템 정보 요약 + 상세 패널
          _buildHostInfoPanel(),
          // 탭 선택기 (AI / 매크로 / 설정)
          _buildTabBar(),
          // 탭 내용
          Expanded(child: _buildTabContent()),
          // AI 탭에서만 입력창 표시
          if (_activeTab == 0) _buildAssistantInput(),
        ],
      ),
    );
  }

  // 어시스턴트 패널 헤더
  Widget _buildAssistantHeader() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          const Icon(Icons.smart_toy_outlined, color: accent, size: 16),
          const SizedBox(width: 8),
          const Text(
            'AI 어시스턴트',
            style: TextStyle(
              color: textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() => _assistantOpen = false),
            child: const Icon(Icons.close, color: textSecondary, size: 16),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 호스트 시스템 정보 패널 (접이식)
  // ──────────────────────────────────────────────────────────────
  Widget _buildHostInfoPanel() {
    if (_lastDiagnostics == null && _osInfo.isEmpty) {
      return const SizedBox.shrink();
    }

    final sys = _lastDiagnostics?['system'] as Map<String, dynamic>?;
    // system은 플랫 구조: cpuUsage, memUsed, memTotal, uptime이 직접 필드
    final cpuUsage = (sys?['cpuUsage'] as num?)?.toInt() ?? _cpuUsage;
    final memUsedMb = (sys?['memUsed'] as num?)?.toInt() ?? _memUsed;
    final memTotalMb = (sys?['memTotal'] as num?)?.toInt() ?? _memTotal;
    final uptimeSec = (sys?['uptime'] as num?)?.toInt() ?? 0;
    final uptimeStr = uptimeSec > 0
        ? '${uptimeSec ~/ 3600}h ${(uptimeSec % 3600) ~/ 60}m'
        : '';

    return Container(
      decoration: const BoxDecoration(
        color: bgCard,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Column(
        children: [
          // 요약 행 (항상 표시)
          GestureDetector(
            onTap: () => setState(() => _diagDetailOpen = !_diagDetailOpen),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.computer, color: accent, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${_osInfo.isNotEmpty ? _osInfo : (sys?['os'] ?? '')}  '
                      'CPU: $cpuUsage%  '
                      'MEM: $memUsedMb/$memTotalMb MB'
                      '${uptimeStr.isNotEmpty ? '  ⏱ $uptimeStr' : ''}',
                      style:
                          const TextStyle(color: textSecondary, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _diagDetailOpen ? Icons.expand_less : Icons.expand_more,
                    color: textSecondary,
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
          // 상세 정보 (펼쳤을 때)
          if (_diagDetailOpen && _lastDiagnostics != null)
            _buildHostInfoDetail(),
        ],
      ),
    );
  }

  // 호스트 상세 정보 위젯
  Widget _buildHostInfoDetail() {
    final diag = _lastDiagnostics!;
    final sys = diag['system'] as Map<String, dynamic>?;
    // system 안에 disks 리스트가 있음 (별도 disk 키가 아님)
    final disks = sys?['disks'] as List<dynamic>?;
    final battery = sys?['battery'] as Map<String, dynamic>?;
    final network = diag['network'] as Map<String, dynamic>?;
    final processes = (diag['processes']?['topCpu'] as List<dynamic>?) ??
        (diag['processes']?['topByMemory'] as List<dynamic>?) ??
        (diag['processes']?['top'] as List<dynamic>?);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: borderColor, height: 8),
          // CPU 모델
          if (sys?['cpuModel'] != null)
            _detailRow('CPU 모델', sys!['cpuModel'].toString()),
          // 디스크 (system.disks 리스트)
          if (disks != null && disks.isNotEmpty) _buildDiskList(disks),
          // 배터리
          if (battery != null) _buildBatteryInfo(battery),
          // 네트워크
          if (network != null) _buildNetworkInfo(network),
          // 상위 프로세스
          if (processes != null && processes.isNotEmpty)
            _buildTopProcesses(processes),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(color: textSecondary, fontSize: 10)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: textPrimary, fontSize: 10)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiskList(List<dynamic> drives) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: drives.take(3).map((d) {
        final m = d as Map<String, dynamic>;
        final mount = m['mount']?.toString() ?? m['drive']?.toString() ?? '';
        final used = (m['used'] as num?)?.toInt() ?? 0;
        final total = (m['total'] as num?)?.toInt() ?? 0;
        return _detailRow('디스크 $mount', '$used / $total GB');
      }).toList(),
    );
  }

  Widget _buildBatteryInfo(Map<String, dynamic> battery) {
    final level =
        battery['percent']?.toString() ?? battery['level']?.toString() ?? '?';
    final charging = battery['isCharging'] as bool? ?? false;
    return _detailRow('배터리', '$level% ${charging ? '⚡ 충전중' : ''}');
  }

  Widget _buildNetworkInfo(Map<String, dynamic> network) {
    final interfaces = (network['interfaces'] as List<dynamic>?)?.take(2) ?? [];
    final dns = (network['dns'] as List<dynamic>?)?.join(', ') ?? '';
    final internet = network['internetConnected'] as bool?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final iface in interfaces)
          _detailRow(
            '네트워크',
            '${(iface as Map)['name'] ?? ''} ${iface['address'] ?? ''}',
          ),
        if (dns.isNotEmpty) _detailRow('DNS', dns),
        if (internet != null) _detailRow('인터넷', internet ? '✅ 연결됨' : '❌ 끊김'),
      ],
    );
  }

  Widget _buildTopProcesses(List<dynamic> processes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 2),
          child: Text('상위 프로세스',
              style: TextStyle(color: textSecondary, fontSize: 10)),
        ),
        ...processes.take(5).map((p) {
          final m = p as Map<String, dynamic>;
          final name = m['name']?.toString() ?? '';
          final mem = m['mem']?.toString() ?? m['memory']?.toString() ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Expanded(
                    child: Text(name,
                        style:
                            const TextStyle(color: textPrimary, fontSize: 10),
                        overflow: TextOverflow.ellipsis)),
                Text(mem,
                    style: const TextStyle(color: textSecondary, fontSize: 10)),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 탭 바 (AI / 채팅 / 매크로 / 설정)
  // ──────────────────────────────────────────────────────────────
  Widget _buildTabBar() {
    // 탭 라벨 목록 (인덱스 순서와 _buildTabContent 분기가 반드시 일치해야 함)
    const tabLabels = ['AI', '채팅', '매크로', '설정'];
    return Container(
      height: 36,
      decoration: const BoxDecoration(
        color: bgPrimary,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: List.generate(tabLabels.length, (i) {
          final isActive = _activeTab == i;
          return Expanded(
            child: GestureDetector(
              onTap: () async {
                setState(() => _activeTab = i);
                // 채팅 탭: 안읽은 수 초기화 + 읽음 처리
                if (i == 1) _onChatTabSelected();
                // 매크로 탭: 목록 자동 로드
                if (i == 2 && _macros.isEmpty && !_macrosLoading) {
                  await _loadMacroTab();
                }
              },
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isActive ? accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                // 채팅 탭에만 안읽은 수 배지 표시
                child: i == 1 && _unreadCount > 0
                    ? Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Text(
                            tabLabels[i],
                            style: TextStyle(
                              color: isActive ? accent : textSecondary,
                              fontSize: 12,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          Positioned(
                            top: -4,
                            right: -12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: danger,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _unreadCount > 99
                                    ? '99+'
                                    : '$_unreadCount',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 9),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Text(
                        tabLabels[i],
                        style: TextStyle(
                          color: isActive ? accent : textSecondary,
                          fontSize: 12,
                          fontWeight:
                              isActive ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // 탭 내용 분기 (0=AI, 1=채팅, 2=매크로, 3=설정)
  Widget _buildTabContent() {
    switch (_activeTab) {
      case 0:
        return _buildAiTab();
      case 1:
        return _buildChatTab();
      case 2:
        return _buildMacroTab();
      case 3:
        return _buildSettingsTab();
      default:
        return const SizedBox.shrink();
    }
  }

  // ──────────────────────────────────────────────────────────────
  // AI 탭 (채팅 + 진단 알림)
  // ──────────────────────────────────────────────────────────────
  Widget _buildAiTab() {
    final activeIssues = _issueService.activeIssues;
    return Column(
      children: [
        // 자동진단 이슈 카드 (승인 요청)
        if (activeIssues.isNotEmpty) _buildIssueApprovalCards(activeIssues),
        // 기존 자동 진단 결과 (뷰어 측 분석)
        if (_diagResults.isNotEmpty) _buildDiagAlerts(),
        Expanded(child: _buildChatArea()),
      ],
    );
  }

  // ── 자동진단 이슈 승인 카드 (PLAN.md 단계 2~3) ─────────────────────
  Widget _buildIssueApprovalCards(List<IssueEvent> issues) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        shrinkWrap: true,
        itemCount: issues.length,
        itemBuilder: (_, i) => _buildIssueCard(issues[i]),
      ),
    );
  }

  Widget _buildIssueCard(IssueEvent issue) {
    final (icon, bg, border) = switch (issue.severity) {
      'critical' => ('🔴', const Color(0x1FE05252), const Color(0x4DE05252)),
      'warning' => ('🟡', const Color(0x1FF0A83A), const Color(0x4DF0A83A)),
      _ => ('🔵', const Color(0x1F4F8EF7), const Color(0x4D4F8EF7)),
    };

    final isActionable = issue.status == 'detected';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '[${issue.category}] ${issue.summary}',
                  style: const TextStyle(
                      color: textPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              // 상태 배지
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isActionable ? accent.withAlpha(40) : textSecondary.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _issueStatusLabel(issue.status),
                  style: TextStyle(
                      color: isActionable ? accent : textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (issue.detail != null) ...[
            const SizedBox(height: 4),
            Text(issue.detail!,
                style: const TextStyle(color: textSecondary, fontSize: 11)),
          ],
          // 승인/무시 버튼 (아직 승인 안 된 상태일 때만)
          if (isActionable) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _issueActionBtn(
                    label: '상세 진단 승인',
                    color: accent,
                    onTap: () => _onApproveDiagnostic(issue),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _issueActionBtn(
                    label: '무시',
                    color: textSecondary,
                    onTap: () => setState(() => _issueService.dismissIssue(issue.id)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _issueActionBtn({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withAlpha(80)),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  String _issueStatusLabel(String status) {
    switch (status) {
      case 'detected': return '승인 필요';
      case 'acknowledged': return '진단 중';
      case 'diagnosed': return '복구 대기';
      case 'recovered': return '복구 완료';
      case 'dismissed': return '무시됨';
      default: return status;
    }
  }

  // 진단 승인 (Level 1: Read-only) + 호스트에 진단 실행 지시
  Future<void> _onApproveDiagnostic(IssueEvent issue) async {
    final result = await _issueService.approveDiagnostic(
      issueId: issue.id,
      approverId: widget.viewerId,
      scopeLevel: 1,
      sessionId: SupabaseService.instance.activeSessionId,
    );
    if (result == null) {
      if (mounted) {
        setState(() => _chatMessages.add(const _ChatMessage(
            text: '❌ 진단 승인 실패', isUser: false, isSystem: true)));
      }
      return;
    }

    // 보안: 서버가 카테고리별 고정 진단 스텝을 사용하므로 뷰어는 지시만 보냄
    // (뷰어가 임의의 command를 주입하지 못하게 함)
    widget.signaling.send({
      'type': 'approve.diagnostic',
      'issueId': issue.id,
      'scopeLevel': 1,
      'approverId': widget.viewerId,
      'approvalToken': result.tokenId,
    });

    if (mounted) {
      setState(() => _chatMessages.add(const _ChatMessage(
          text: '⏳ 상세 진단 실행 중...',
          isUser: false,
          isSystem: true)));
    }
  }

  // 자동진단 WS 메시지 분기 처리
  void _handleDiagnosisMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    switch (type) {
      case 'issue.notified':
        _issueService.handleNotified(msg);
        if (mounted) {
          setState(() => _chatMessages.add(_ChatMessage(
              text: '🚨 [${msg['severity']}] ${msg['summary']}',
              isUser: false,
              isSystem: true)));
        }
        return;

      case 'diagnostic.progress':
      case 'recovery.progress':
        final progress = (msg['progress'] as num?)?.toInt() ?? 0;
        final stepName = msg['stepName']?.toString() ?? '';
        debugPrint('[progress] $progress% - $stepName');
        return;

      case 'diagnostic.result':
        _renderDiagnosticResult(msg);
        return;

      case 'recovery.result':
        _renderRecoveryResult(msg);
        return;

      case 'verification.result':
        final success = msg['success'] == true;
        if (mounted) {
          setState(() => _chatMessages.add(_ChatMessage(
              text: success ? '✅ 복구 검증 통과' : '⚠️ 복구 검증 실패 — 추가 조치 필요',
              isUser: false,
              isSystem: true)));
        }
        return;

      default:
        return;
    }
  }

  // 진단 결과를 채팅에 표시 + 권장 플레이북 로드 → 복구 승인 UI 제공
  Future<void> _renderDiagnosticResult(Map<String, dynamic> msg) async {
    final issueId = msg['issueId']?.toString() ?? '';
    final candidates = (msg['rootCauseCandidates'] as List?) ?? [];

    final buf = StringBuffer('🔍 진단 결과:\n');
    for (final c in candidates.take(3)) {
      final m = c as Map<String, dynamic>;
      final confidencePct = ((m['confidence'] as num?)?.toDouble() ?? 0) * 100;
      buf.writeln('• ${m['cause']} (신뢰도 ${confidencePct.toInt()}%)');
    }
    if (mounted) {
      setState(() => _chatMessages.add(_ChatMessage(
          text: buf.toString().trim(), isUser: false)));
    }

    // 이슈 카테고리로 권장 플레이북 조회 (DB 기반)
    final issue = _issueService.issues.firstWhere(
      (i) => i.id == issueId,
      orElse: () => IssueEvent(
        id: issueId, category: 'general', severity: 'warning',
        summary: '', detectedAt: DateTime.now(),
      ),
    );

    final playbooks = await _issueService.loadPlaybooks(category: issue.category);
    if (playbooks.isEmpty) return;

    // 권장 복구 카드 (actionWidget으로 추가하여 채팅 내 버튼 렌더)
    if (mounted) {
      setState(() => _chatMessages.add(_ChatMessage(
        text: '',
        isUser: false,
        actionWidget: _buildRecoveryRecommendCard(issue, playbooks),
      )));
    }
  }

  // 권장 복구 카드 (진단 결과 뒤에 표시)
  Widget _buildRecoveryRecommendCard(IssueEvent issue, List<Map<String, dynamic>> playbooks) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('🛠 권장 복구',
              style: TextStyle(
                  color: textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...playbooks.take(5).map((p) => _buildPlaybookRow(issue, p)),
        ],
      ),
    );
  }

  Widget _buildPlaybookRow(IssueEvent issue, Map<String, dynamic> pb) {
    final name = pb['name']?.toString() ?? '';
    final riskLevel = pb['risk_level']?.toString() ?? 'medium';
    final requiredLevel = (pb['required_approval_level'] as num?)?.toInt() ?? 2;
    final (riskColor, riskLabel) = switch (riskLevel) {
      'low' => (success, '낮음'),
      'medium' => (warning, '중간'),
      'high' => (danger, '높음'),
      'critical' => (danger, '매우 높음'),
      _ => (textSecondary, riskLevel),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(color: textPrimary, fontSize: 12)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: riskColor.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('위험도 $riskLabel',
                          style: TextStyle(color: riskColor, fontSize: 10)),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: accent.withAlpha(30),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('Level $requiredLevel',
                          style: const TextStyle(color: accent, fontSize: 10)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _onApproveRecovery(issue, pb),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: accent.withAlpha(30),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: accent.withAlpha(80)),
              ),
              child: const Text('실행',
                  style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  // 복구 승인 + 실행 (Level 2~4, 고위험은 재확인 다이얼로그)
  Future<void> _onApproveRecovery(IssueEvent issue, Map<String, dynamic> pb) async {
    final requiredLevel = (pb['required_approval_level'] as num?)?.toInt() ?? 2;
    final riskLevel = pb['risk_level']?.toString() ?? 'medium';
    final name = pb['name']?.toString() ?? '복구';
    final pbId = pb['id']?.toString() ?? '';

    // Level 3 이상은 재확인
    if (requiredLevel >= 3) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: bgCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: Text('⚠️ $name',
              style: const TextStyle(
                  color: textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
          content: Text(
            '위험도: $riskLevel\n승인 Level $requiredLevel 필요\n\n이 복구는 시스템에 영향을 줄 수 있습니다. 실행하시겠습니까?',
            style: const TextStyle(color: textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소', style: TextStyle(color: textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('실행 승인', style: TextStyle(color: danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    // 승인 토큰 발급
    final result = await _issueService.approveRecovery(
      issueId: issue.id,
      approverId: widget.viewerId,
      scopeLevel: requiredLevel,
      allowedActionIds: [pbId],
      sessionId: SupabaseService.instance.activeSessionId,
    );
    if (result == null) {
      if (mounted) {
        setState(() => _chatMessages.add(const _ChatMessage(
            text: '❌ 복구 승인 실패', isUser: false, isSystem: true)));
      }
      return;
    }

    // 보안: 뷰어는 playbookId만 전달 — 서버가 DB에서 조회 후 호스트에 실제 명령 전송
    // 뷰어가 임의의 command를 주입하지 못하게 함
    widget.signaling.send({
      'type': 'approve.recovery',
      'issueId': issue.id,
      'playbookId': pbId,
      'scopeLevel': requiredLevel,
      'approverId': widget.viewerId,
      'approvalToken': result.tokenId,
    });

    if (mounted) {
      setState(() => _chatMessages.add(_ChatMessage(
          text: '⏳ 복구 실행 중: $name',
          isUser: false,
          isSystem: true)));
    }
  }

  // 복구 결과를 채팅에 표시
  void _renderRecoveryResult(Map<String, dynamic> msg) {
    final success = msg['success'] == true;
    final rolled = msg['rolledBack'] == true;
    final steps = (msg['stepResults'] as List?) ?? [];
    final buf = StringBuffer(
        success ? '✅ 복구 완료\n' : (rolled ? '↩️ 롤백됨\n' : '❌ 복구 실패\n'));
    for (final s in steps.take(5)) {
      final m = s as Map<String, dynamic>;
      buf.writeln('  ${m['status'] == 'success' ? '✓' : '✗'} ${m['stepName']}');
    }
    if (mounted) {
      setState(() => _chatMessages.add(_ChatMessage(
          text: buf.toString().trim(), isUser: false)));
    }
  }

  // 주의: 뷰어 측 _getDiagnosticSteps는 제거됨.
  // 보안 강화: 진단 스텝은 서버(diagnosis-ws.ts)의 DIAGNOSTIC_STEPS_BY_CATEGORY에서
  // 카테고리별로 고정 정의하여 호스트에 전달. 뷰어가 임의 명령을 주입하지 못함.

  Widget _buildDiagAlerts() {
    final severityOrder = {
      Severity.critical: 0,
      Severity.warning: 1,
      Severity.info: 2,
      Severity.ok: 3,
    };
    final sorted = [..._diagResults]..sort((a, b) =>
        (severityOrder[a.severity] ?? 3) - (severityOrder[b.severity] ?? 3));

    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        shrinkWrap: true,
        itemCount: sorted.length,
        itemBuilder: (_, i) {
          final r = sorted[i];
          final (icon, bg, border) = switch (r.severity) {
            Severity.critical => (
                '🔴',
                const Color(0x1FE05252),
                const Color(0x4DE05252)
              ),
            Severity.warning => (
                '🟡',
                const Color(0x1FF0A83A),
                const Color(0x4DF0A83A)
              ),
            Severity.info => (
                '🔵',
                const Color(0x1A4F8EF7),
                const Color(0x334F8EF7)
              ),
            Severity.ok => (
                '🟢',
                const Color(0x1A4CAF7D),
                const Color(0x334CAF7D)
              ),
          };
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(icon, style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '[${r.category}] ${r.title}',
                        style: const TextStyle(
                            color: textPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(r.detail,
                          style: const TextStyle(
                              color: textSecondary, fontSize: 10)),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildChatArea() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _chatMessages.length + (_assistantLoading ? 1 : 0),
      itemBuilder: (_, index) {
        if (_assistantLoading && index == _chatMessages.length) {
          return _buildLoadingBubble();
        }
        return _buildMessageBubble(_chatMessages[index]);
      },
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg) {
    // actionWidget이 있는 경우 (매크로/플레이북 목록 등)
    if (msg.actionWidget != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: msg.actionWidget!,
      );
    }

    // 시스템 메시지: 이탤릭, 가운데 정렬, 작은 글씨
    if (msg.isSystem) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Center(
          child: SelectableText(
            msg.text,
            style: const TextStyle(
              color: textSecondary,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: msg.isUser ? accent.withAlpha(40) : bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: msg.isUser ? accent.withAlpha(80) : borderColor,
          ),
        ),
        child: SelectableText(
          msg.text,
          style: const TextStyle(color: textPrimary, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: const SizedBox(
          width: 40,
          height: 16,
          child: _LoadingDots(),
        ),
      ),
    );
  }

  Widget _buildAssistantInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _assistantController,
              style: const TextStyle(color: textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: '질문 또는 /macro, /playbook',
                hintStyle: const TextStyle(color: textSecondary, fontSize: 12),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: accent),
                ),
                filled: true,
                fillColor: bgCard,
              ),
              onSubmitted: _sendAssistantQuery,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _sendAssistantQuery(_assistantController.text),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 매크로 탭 (목록 + 플레이북)
  // ──────────────────────────────────────────────────────────────

  // 매크로 탭 선택 시 Supabase에서 목록 로드
  Future<void> _loadMacroTab() async {
    setState(() => _macrosLoading = true);
    final results = await Future.wait([
      _assistantService.fetchMacros(),
      _assistantService.fetchPlaybooks(),
    ]);
    if (mounted) {
      setState(() {
        _macros = results[0] as List<MacroItem>;
        _playbooks = results[1] as List<PlaybookItem>;
        _macrosLoading = false;
      });
    }
  }

  Widget _buildMacroTab() {
    if (_macrosLoading) {
      return const Center(
        child: CircularProgressIndicator(color: accent),
      );
    }

    // 호스트 플랫폼에 맞는 매크로만 표시
    final filtered = _macros.where((m) {
      return m.os == 'all' || _hostPlatform.isEmpty || m.os == _hostPlatform;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 새로고침 버튼
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _loadMacroTab,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: bgCard,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: borderColor),
                ),
                child: const Text('새로고침',
                    style: TextStyle(color: textSecondary, fontSize: 11)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 매크로 목록
          if (filtered.isNotEmpty) ...[
            const Text('매크로',
                style: TextStyle(
                    color: textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ...filtered.map((m) => _buildMacroCard(m)),
            const SizedBox(height: 12),
          ],
          // 플레이북 목록
          if (_playbooks.isNotEmpty) ...[
            const Text('플레이북',
                style: TextStyle(
                    color: textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            ..._playbooks.map((p) => _buildPlaybookCard(p)),
          ],
          if (filtered.isEmpty && _playbooks.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 32),
                child: Text('사용 가능한 매크로/플레이북이 없습니다.',
                    style: TextStyle(color: textSecondary, fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  // 매크로 카드 위젯
  Widget _buildMacroCard(MacroItem macro) {
    final osIcon = _osIcons[macro.os] ?? '🌐';
    final categoryLabel = _categoryLabels[macro.category] ?? macro.category;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: macro.isDangerous ? danger.withAlpha(80) : borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(osIcon, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  macro.name,
                  style: const TextStyle(
                      color: textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  categoryLabel,
                  style: const TextStyle(color: accent, fontSize: 9),
                ),
              ),
            ],
          ),
          if (macro.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(macro.description,
                style: const TextStyle(color: textSecondary, fontSize: 11)),
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (macro.isDangerous)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('⚠️ 위험',
                      style: TextStyle(color: danger, fontSize: 10)),
                ),
              GestureDetector(
                onTap: () => _executeMacro(macro),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: macro.isDangerous
                        ? danger.withAlpha(40)
                        : accent.withAlpha(40),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: macro.isDangerous
                          ? danger.withAlpha(80)
                          : accent.withAlpha(80),
                    ),
                  ),
                  child: Text(
                    '실행',
                    style: TextStyle(
                      color: macro.isDangerous ? danger : accent,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 플레이북 카드 위젯
  Widget _buildPlaybookCard(PlaybookItem playbook) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.playlist_play, color: accent, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  playbook.name,
                  style: const TextStyle(
                      color: textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: success.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${playbook.steps.length}단계',
                  style: const TextStyle(color: success, fontSize: 9),
                ),
              ),
            ],
          ),
          if (playbook.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(playbook.description,
                style: const TextStyle(color: textSecondary, fontSize: 11)),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () => _executePlaybook(playbook),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: accent.withAlpha(40),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: accent.withAlpha(80)),
                ),
                child: const Text('실행',
                    style: TextStyle(color: accent, fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 채팅 탭 (실시간 1:1 메시지)
  // ──────────────────────────────────────────────────────────────
  Widget _buildChatTab() {
    // 채팅방이 아직 연결되지 않은 경우
    if (_chatLoading) {
      return const Center(child: CircularProgressIndicator(color: accent));
    }
    if (_chatService.chatRoomId == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('채팅 연결 대기 중',
                style: TextStyle(color: textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _initChat,
              child: const Text('재시도', style: TextStyle(color: accent, fontSize: 12)),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // 메시지 목록
        Expanded(
          child: _chatHistory.isEmpty
              ? const Center(
                  child: Text('메시지가 없습니다.',
                      style: TextStyle(color: textSecondary, fontSize: 12)),
                )
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _chatHistory.length,
                  itemBuilder: (_, i) => _buildChatBubble(_chatHistory[i]),
                ),
        ),
        // 입력 바
        _buildChatInput(),
      ],
    );
  }

  // 채팅 말풍선 위젯
  // isThreadView=true이면 스레드 패널 내부 — 답글 배지/버튼 표시 안 함 (1단계 깊이 정책)
  Widget _buildChatBubble(ChatRoomMessage msg, {bool isThreadView = false}) {
    // 시스템 메시지는 가운데 작은 텍스트로 표시
    if (msg.messageType == 'system' || msg.senderType == 'system') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Center(
          child: SelectableText(
            msg.content,
            style: const TextStyle(
                color: textSecondary, fontSize: 11, fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final isMe = msg.senderId == widget.viewerId;
    final timeStr =
        '${msg.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${msg.createdAt.toLocal().minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(
              bottom: (msg.replyCount > 0 && !isThreadView) ? 2 : 8,
              left: isMe ? 48 : 0,
              right: isMe ? 0 : 48,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isMe ? accent.withAlpha(40) : bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isMe ? accent.withAlpha(80) : borderColor,
              ),
            ),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // 발신자 유형 표시 (상대방 메시지에만)
                if (!isMe)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      msg.senderType == 'host' ? '호스트' : '뷰어',
                      style: const TextStyle(color: accent, fontSize: 10),
                    ),
                  ),
                SelectableText(msg.content,
                    style: const TextStyle(color: textPrimary, fontSize: 13)),
                const SizedBox(height: 3),
                Text(timeStr,
                    style: const TextStyle(color: textSecondary, fontSize: 10)),
              ],
            ),
          ),
          // 스레드 패널 내부에서는 배지/버튼 표시 안 함 (1단계 깊이 정책)
          if (!isThreadView) ...[
            // 답글이 있으면 "답글 N개" 배지 표시
            if (msg.replyCount > 0)
              GestureDetector(
                onTap: () => _openThreadPanel(msg),
                child: Container(
                  margin: EdgeInsets.only(
                    bottom: 4,
                    left: isMe ? 48 : 0,
                    right: isMe ? 0 : 48,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accent.withAlpha(20),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: accent.withAlpha(60)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline, size: 11, color: accent),
                      const SizedBox(width: 4),
                      Text(
                        '답글 ${msg.replyCount}개',
                        style: TextStyle(color: accent, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            // "답글 달기" 버튼 (답글 0개여도 스레드 시작 가능)
            GestureDetector(
              onTap: () => _openThreadPanel(msg),
              child: Container(
                margin: EdgeInsets.only(
                  bottom: 8,
                  left: isMe ? 48 : 0,
                  right: isMe ? 0 : 48,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: borderColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply, size: 11, color: textSecondary),
                    SizedBox(width: 3),
                    Text('답글 달기', style: TextStyle(color: textSecondary, fontSize: 10)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 채팅 입력 바
  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatInputController,
              style: const TextStyle(color: textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: '메시지 입력...',
                hintStyle: const TextStyle(color: textSecondary, fontSize: 12),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: accent),
                ),
                filled: true,
                fillColor: bgCard,
              ),
              onSubmitted: _sendChatMessage,
              // 타이핑 알림 전송
              onChanged: (_) {
                if (_chatService.chatRoomId != null) {
                  widget.signaling.sendChatMessage({
                    'type': 'chat-typing',
                    'chatRoomId': _chatService.chatRoomId!,
                    'userId': widget.viewerId,
                  });
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _sendChatMessage(_chatInputController.text),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 설정 탭 (placeholder)
  // ──────────────────────────────────────────────────────────────
  Widget _buildSettingsTab() {
    return const Center(
      child: Text(
        '설정 기능은 추후 추가될 예정입니다.',
        style: TextStyle(color: textSecondary, fontSize: 12),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────
  // 채팅에서 /macro 명령 실행 시 표시하는 매크로 목록 위젯
  // ──────────────────────────────────────────────────────────────
  Widget _buildMacroListWidget(List<MacroItem> macros) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('사용 가능한 매크로',
              style: TextStyle(
                  color: textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...macros.map((m) => _buildInlineMacroRow(m)),
        ],
      ),
    );
  }

  Widget _buildInlineMacroRow(MacroItem macro) {
    final osIcon = _osIcons[macro.os] ?? '🌐';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(osIcon, style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(macro.name,
                    style: const TextStyle(color: textPrimary, fontSize: 11)),
                if (macro.description.isNotEmpty)
                  Text(macro.description,
                      style:
                          const TextStyle(color: textSecondary, fontSize: 10)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _executeMacro(macro),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withAlpha(40),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: accent.withAlpha(80)),
              ),
              child: const Text('실행',
                  style: TextStyle(color: accent, fontSize: 10)),
            ),
          ),
        ],
      ),
    );
  }

  // 채팅에서 /playbook 명령 실행 시 표시하는 플레이북 목록 위젯
  Widget _buildPlaybookListWidget(List<PlaybookItem> playbooks) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('사용 가능한 플레이북',
              style: TextStyle(
                  color: textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...playbooks.map((p) => _buildInlinePlaybookRow(p)),
        ],
      ),
    );
  }

  Widget _buildInlinePlaybookRow(PlaybookItem playbook) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.playlist_play, color: accent, size: 13),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(playbook.name,
                    style: const TextStyle(color: textPrimary, fontSize: 11)),
                Text('${playbook.steps.length}단계 • ${playbook.description}',
                    style: const TextStyle(color: textSecondary, fontSize: 10),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _executePlaybook(playbook),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: accent.withAlpha(40),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: accent.withAlpha(80)),
              ),
              child: const Text('실행',
                  style: TextStyle(color: accent, fontSize: 10)),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// 로딩 점 애니메이션
// ──────────────────────────────────────────────────────────────
class _LoadingDots extends StatefulWidget {
  const _LoadingDots();

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final phase = (t - i * 0.2).clamp(0.0, 1.0);
            final opacity =
                (phase < 0.5 ? phase * 2 : (1 - phase) * 2).clamp(0.3, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: textSecondary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
