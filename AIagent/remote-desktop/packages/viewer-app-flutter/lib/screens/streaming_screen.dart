import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../app_theme.dart';
import '../peer_connection.dart';
import '../signaling.dart';
import '../services/supabase_service.dart';
import '../services/assistant_service.dart';

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

  // 호스트 정보
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

  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _assistantService = AssistantService(
      serverUrl: widget.serverUrl.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://'),
    );
    _initRenderer();
    _setupSignaling();
    _setupPeerConnection();
  }

  @override
  void dispose() {
    _remoteRenderer.dispose();
    _pc.close();
    _assistantController.dispose();
    SupabaseService.instance.endSession('user-disconnect');
    super.dispose();
  }

  Future<void> _initRenderer() async {
    await _remoteRenderer.initialize();
  }

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
      if (mounted) {
        setState(() => _remoteRenderer.srcObject = stream);
      }
    };

    _pc.onChannelOpen = (_) {
      SupabaseService.instance.startSession(
        widget.roomId,
        widget.viewerId,
      );
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
      case 'source-changed':
        final sourceId = msg['sourceId']?.toString() ?? '';
        if (mounted) setState(() => _activeSourceId = sourceId);
    }
  }

  void _updateRenderBounds() {
    final box = _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _renderSize = box.size;
    _renderOffset = box.localToGlobal(Offset.zero);
  }

  void _onPointerMove(PointerEvent event) {
    _updateRenderBounds();
    if (_renderSize == Size.zero) return;
    final localX = event.position.dx - _renderOffset.dx;
    final localY = event.position.dy - _renderOffset.dy;
    final nx = (localX / _renderSize.width).clamp(0.0, 1.0);
    final ny = (localY / _renderSize.height).clamp(0.0, 1.0);
    _pc.sendMessage({'type': 'mousemove', 'x': nx, 'y': ny});
  }

  void _onPointerDown(PointerEvent event) {
    _updateRenderBounds();
    if (_renderSize == Size.zero) return;
    final localX = event.position.dx - _renderOffset.dx;
    final localY = event.position.dy - _renderOffset.dy;
    final nx = (localX / _renderSize.width).clamp(0.0, 1.0);
    final ny = (localY / _renderSize.height).clamp(0.0, 1.0);
    _pc.sendMessage({'type': 'mousedown', 'button': 0, 'x': nx, 'y': ny});
  }

  void _onPointerUp(PointerEvent event) {
    _updateRenderBounds();
    if (_renderSize == Size.zero) return;
    final localX = event.position.dx - _renderOffset.dx;
    final localY = event.position.dy - _renderOffset.dy;
    final nx = (localX / _renderSize.width).clamp(0.0, 1.0);
    final ny = (localY / _renderSize.height).clamp(0.0, 1.0);
    _pc.sendMessage({'type': 'mouseup', 'button': 0, 'x': nx, 'y': ny});
  }

  void _onScroll(PointerScrollEvent event) {
    _pc.sendMessage({
      'type': 'scroll',
      'deltaX': event.scrollDelta.dx,
      'deltaY': event.scrollDelta.dy,
    });
  }

  void _switchSource(String sourceId) {
    _pc.sendMessage({'type': 'switch-source', 'sourceId': sourceId});
    setState(() => _activeSourceId = sourceId);
  }

  void _disconnect() {
    widget.signaling.disconnect();
    _pc.close();
    Navigator.of(context).popUntil((route) => route.isFirst);
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

  Future<void> _sendAssistantQuery(String query) async {
    if (query.trim().isEmpty) return;
    _assistantController.clear();
    setState(() {
      _chatMessages.add(_ChatMessage(text: query, isUser: true));
      _assistantLoading = true;
    });
    final resp = await _assistantService.askAssistant(query);
    if (mounted) {
      setState(() {
        _chatMessages.add(_ChatMessage(text: resp.answer, isUser: false));
        _assistantLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgPrimary,
      body: Column(
        children: [
          if (!_fullscreen) _buildStatusBar(),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildVideoArea()),
                if (_assistantOpen) _buildAssistantPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    final (stateLabel, stateColor) = switch (_connState) {
      RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
        ('연결됨', success),
      RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
        ('연결 중', warning),
      RTCPeerConnectionState.RTCPeerConnectionStateFailed => ('실패', danger),
      RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
        ('끊김', danger),
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
          Text(
            stateLabel,
            style: TextStyle(color: stateColor, fontSize: 12),
          ),
          if (_osInfo.isNotEmpty) ...[
            const SizedBox(width: 16),
            Text(
              _osInfo,
              style: const TextStyle(color: textSecondary, fontSize: 12),
            ),
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
          // AI 어시스턴트 토글
          _buildIconBtn(
            icon: Icons.smart_toy_outlined,
            tooltip: 'AI 어시스턴트',
            active: _assistantOpen,
            onTap: () => setState(() => _assistantOpen = !_assistantOpen),
          ),
          const SizedBox(width: 4),
          // 전체화면 토글
          _buildIconBtn(
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            tooltip: _fullscreen ? '전체화면 해제' : '전체화면',
            onTap: () => setState(() => _fullscreen = !_fullscreen),
          ),
          const SizedBox(width: 4),
          // 연결 종료
          _buildIconBtn(
            icon: Icons.stop_circle_outlined,
            tooltip: '연결 종료',
            color: danger,
            onTap: _disconnect,
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
          border: Border.all(
            color: isActive ? accent : borderColor,
          ),
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

  Widget _buildVideoArea() {
    return Listener(
      onPointerMove: _onPointerMove,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) _onScroll(event);
      },
      child: Container(
        color: Colors.black,
        child: RTCVideoView(
          key: _videoKey,
          _remoteRenderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }

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
          Expanded(child: _buildChatArea()),
          _buildAssistantInput(),
        ],
      ),
    );
  }

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
    return Align(
      alignment:
          msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: msg.isUser ? accent.withAlpha(40) : bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: msg.isUser ? accent.withAlpha(80) : borderColor,
          ),
        ),
        child: Text(
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
                hintText: '질문을 입력하세요...',
                hintStyle: const TextStyle(color: textSecondary, fontSize: 13),
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
}

class _ChatMessage {
  final String text;
  final bool isUser;

  const _ChatMessage({required this.text, required this.isUser});
}

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
            final opacity = (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                .clamp(0.3, 1.0);
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
