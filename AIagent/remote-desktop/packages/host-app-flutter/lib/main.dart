import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dart:async';
import 'dart:io' show Platform;
import 'signaling.dart';
import 'peer_manager.dart';
import 'input_handler.dart';
import 'command_executor.dart';
import 'system_diagnostics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HostApp());
}

class HostApp extends StatelessWidget {
  const HostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteCall-mini Host',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0f1117),
        colorScheme: const ColorScheme.dark(
          surface: Color(0xFF1e2130),
          primary: Color(0xFF4f8ef7),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1e2130),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2e3250)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF2e3250)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF4f8ef7)),
          ),
          labelStyle: const TextStyle(color: Color(0xFF8b9cc8)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4f8ef7),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: const HostHomePage(),
    );
  }
}

enum ConnectionState { idle, connecting, connected, error }

class HostHomePage extends StatefulWidget {
  const HostHomePage({super.key});

  @override
  State<HostHomePage> createState() => _HostHomePageState();
}

class _HostHomePageState extends State<HostHomePage> {
  final _serverUrlController = TextEditingController(
    text: 'ws://localhost:8080',
  );
  final _roomIdController = TextEditingController();
  final _previewRenderer = RTCVideoRenderer();

  final _signaling = SignalingClient();
  final _peerManager = PeerManager();
  final _inputHandler = InputHandler();
  final _commandExecutor = CommandExecutor();
  final _diagnostics = SystemDiagnostics();
  Timer? _diagTimer;

  ConnectionState _connState = ConnectionState.idle;
  String _statusMessage = '대기 중';
  String? _currentRoomId;

  @override
  void initState() {
    super.initState();
    _previewRenderer.initialize();
    _setupPeerManagerCallbacks();
  }

  @override
  void dispose() {
    _previewRenderer.dispose();
    _serverUrlController.dispose();
    _roomIdController.dispose();
    _signaling.disconnect();
    _peerManager.close();
    super.dispose();
  }

  void _setupPeerManagerCallbacks() {
    _peerManager.onAnswerReady = (answer, viewerId) {
      _signaling.send({
        'type': 'answer',
        'sdp': {'type': answer.type, 'sdp': answer.sdp},
        'viewerId': viewerId,
      });
    };

    _peerManager.onIceCandidate = (candidate, viewerId) {
      _signaling.send({
        'type': 'ice-candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
        'viewerId': viewerId,
      });
    };

    _peerManager.onDataChannelMessage = (msg) {
      _inputHandler.handleInput(msg);
    };

    _peerManager.onControlMessage = (msg) {
      _handleControlMessage(msg);
    };
  }

  Future<void> _handleControlMessage(Map<String, dynamic> msg) async {
    final type = msg['type'] as String?;
    switch (type) {
      case 'switch-source':
        final sourceId = msg['sourceId'] as String?;
        if (sourceId != null) {
          debugPrint('[control] switch-source: $sourceId');
          await _peerManager.switchSource(sourceId);
        }
      case 'source-changed':
        final bounds = msg['bounds'] as Map<String, dynamic>?;
        if (bounds != null) {
          _inputHandler.setActiveBounds(
            ScreenBounds(
              left: (bounds['x'] as num?)?.toInt() ?? 0,
              top: (bounds['y'] as num?)?.toInt() ?? 0,
              width: (bounds['width'] as num?)?.toInt() ?? 1920,
              height: (bounds['height'] as num?)?.toInt() ?? 1080,
              scaleFactor: (bounds['scaleFactor'] as num?)?.toDouble() ?? 1.0,
            ),
          );
        }
      case 'execute-macro':
        final macroId = msg['macroId'] as String? ?? '';
        final command = msg['command'] as String? ?? '';
        final commandType = msg['commandType'] as String? ?? 'cmd';
        debugPrint('[control] execute-macro: $command ($commandType)');
        final result = await _commandExecutor.execute(command, commandType);
        _peerManager.sendToViewer({
          'type': 'macro-result',
          'macroId': macroId,
          ...result,
        });
      default:
        debugPrint('[control] 처리되지 않은 컨트롤 메시지: $type');
    }
  }

  Future<void> _connectToRoom(String roomId) async {
    final serverUrl = _serverUrlController.text.trim();
    if (serverUrl.isEmpty) return;

    setState(() {
      _connState = ConnectionState.connecting;
      _statusMessage = '시그널링 서버에 연결 중...';
      _currentRoomId = roomId;
    });

    _signaling.onMessage = _handleSignalingMessage;
    _signaling.onDisconnected = () {
      if (mounted) {
        setState(() {
          _connState = ConnectionState.idle;
          _statusMessage = '연결이 끊어졌습니다';
        });
      }
    };

    try {
      await _signaling.connect(serverUrl);
      _signaling.send({
        'type': 'join',
        'roomId': roomId,
        'password': 'nopass',
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _connState = ConnectionState.error;
          _statusMessage = '연결 실패: $e';
        });
        _showErrorDialog('연결 실패', '$e');
      }
    }
  }

  void _handleSignalingMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;

    switch (type) {
      case 'room-info':
        if (mounted) {
          setState(() {
            _connState = ConnectionState.connected;
            _statusMessage = '방 참가 완료 — 뷰어 대기 중';
          });
          _startDiagTimer();
        }

      case 'offer':
        final viewerId = msg['viewerId'] as String;
        final sdp = msg['sdp'] as Map<String, dynamic>;
        _handleOffer(viewerId, sdp);

      case 'ice-candidate':
        final viewerId = msg['viewerId'] as String;
        final candidate = msg['candidate'] as Map<String, dynamic>;
        _peerManager.handleIceCandidate(viewerId, candidate);

      case 'error':
        final message = msg['message'] as String? ?? '알 수 없는 오류';
        if (mounted) {
          setState(() {
            _connState = ConnectionState.error;
            _statusMessage = '오류: $message';
          });
          _showErrorDialog('서버 오류', message);
        }
    }
  }

  Future<void> _handleOffer(
    String viewerId,
    Map<String, dynamic> sdp,
  ) async {
    if (mounted) {
      setState(() => _statusMessage = '뷰어 연결 중...');
    }

    try {
      await _peerManager.handleOffer(viewerId, sdp);

      // 화면 캡처 스트림을 미리보기 렌더러에 연결
      final stream = _peerManager.localStream;
      if (stream != null && mounted) {
        _previewRenderer.srcObject = stream;
        setState(() => _statusMessage = '뷰어와 연결됨');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connState = ConnectionState.error;
          _statusMessage = 'Offer 처리 실패: $e';
        });
        _showErrorDialog('연결 오류', '$e');
      }
    }
  }

  void _startDiagTimer() {
    _stopDiagTimer();
    _diagTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_peerManager.isConnected) {
        _stopDiagTimer();
        return;
      }
      try {
        final basic = await _diagnostics.collectBasic();
        _peerManager.sendToViewer({
          'type': 'host-info',
          'info': {
            'os': '${basic['os']} ${Platform.operatingSystem}',
            'version': basic['osVersion'] ?? '',
            'cpuModel': 'CPU x${basic['cpuCount']}',
            'cpuUsage': 0,
            'memTotal': basic['totalMemoryMB'] ?? 0,
            'memUsed': (basic['totalMemoryMB'] ?? 0) - (basic['freeMemoryMB'] ?? 0),
            'uptime': 0,
          },
        });

        final diag = await _diagnostics.collect();
        _peerManager.sendToViewer({
          'type': 'host-diagnostics',
          'diagnostics': diag,
        });
      } catch (e) {
        debugPrint('[diag] 진단 전송 실패: $e');
      }
    });
  }

  void _stopDiagTimer() {
    _diagTimer?.cancel();
    _diagTimer = null;
  }

  void _disconnect({bool showEndDialog = false}) {
    _stopDiagTimer();
    final wasConnected = _connState == ConnectionState.connected;
    _peerManager.close();
    _signaling.disconnect();
    _previewRenderer.srcObject = null;
    setState(() {
      _connState = ConnectionState.idle;
      _statusMessage = '대기 중';
      _currentRoomId = null;
      _roomIdController.clear();
    });
    if ((showEndDialog || wasConnected) && mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          backgroundColor: const Color(0xFF1e2130),
          title: const Text('상담 종료', style: TextStyle(color: Color(0xFFe8eaf0))),
          content: const Text('상담이 종료되었습니다.', style: TextStyle(color: Color(0xFF8b90a4))),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('확인', style: TextStyle(color: Color(0xFF4f8ef7))),
            ),
          ],
        ),
      );
    }
  }

  void _showErrorDialog(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1e2130),
        title: Text(title, style: const TextStyle(color: Color(0xFFe8eaf0))),
        content: Text(
          message,
          style: const TextStyle(color: Color(0xFF8b9cc8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              '확인',
              style: TextStyle(color: Color(0xFF4f8ef7)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0f1117),
      body: Column(
        children: [
          _buildAppHeader(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 320,
                    child: _buildConnectPanel(),
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: _buildSharePanel()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppHeader() {
    final (badgeLabel, badgeColor) = switch (_connState) {
      ConnectionState.idle => ('대기 중', const Color(0xFF8b90a4)),
      ConnectionState.connecting => ('연결 중', const Color(0xFFf0a83a)),
      ConnectionState.connected => ('연결됨', const Color(0xFF4caf7d)),
      ConnectionState.error => ('오류', const Color(0xFFe05252)),
    };

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF1a1d27),
        border: Border(
          bottom: BorderSide(color: Color(0xFF2e3347)),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'RemoteCall-mini Host',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFFe8eaf0),
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: badgeColor.withAlpha(30),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: badgeColor.withAlpha(100)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: badgeColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  badgeLabel,
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectPanel() {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionCard(
            title: '뷰어 접속',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildFieldLabel('중계서버'),
                const SizedBox(height: 6),
                _buildServerUrlField(),
                const SizedBox(height: 16),
                _buildFieldLabel('접속번호'),
                const SizedBox(height: 6),
                _buildRoomIdField(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _buildStatusCard(),
          if (_connState == ConnectionState.connected) ...[
            const SizedBox(height: 12),
            _buildDisconnectButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildSharePanel() {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: _buildSectionCard(
        title: '화면 공유',
        child: Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_connState == ConnectionState.connected &&
                  _currentRoomId != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const Text(
                        '방 번호:',
                        style: TextStyle(
                          color: Color(0xFF8b90a4),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _currentRoomId!,
                        style: const TextStyle(
                          color: Color(0xFF4f8ef7),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 4,
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(child: _buildPreview()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1e2130),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2e3347)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFe8eaf0),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Divider(color: Color(0xFF2e3347), height: 20),
          child,
        ],
      ),
    );
  }

  Widget _buildFieldLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        color: Color(0xFF8b90a4),
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _buildServerUrlField() {
    final isEditable = _connState == ConnectionState.idle ||
        _connState == ConnectionState.error;

    return TextField(
      controller: _serverUrlController,
      enabled: isEditable,
      style: const TextStyle(color: Color(0xFFe8eaf0), fontSize: 13),
      decoration: const InputDecoration(
        hintText: 'ws://localhost:8080',
        hintStyle: TextStyle(color: Color(0xFF4a5068), fontSize: 13),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
    );
  }

  Widget _buildRoomIdField() {
    final isEditable = _connState == ConnectionState.idle ||
        _connState == ConnectionState.error;

    return TextField(
      controller: _roomIdController,
      enabled: isEditable,
      maxLength: 6,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Color(0xFFe8eaf0),
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: 10,
      ),
      decoration: const InputDecoration(
        hintText: '------',
        hintStyle: TextStyle(
          color: Color(0xFF3a3f58),
          fontSize: 28,
          letterSpacing: 10,
        ),
        counterText: '',
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      onChanged: (value) {
        if (value.length == 6) {
          _connectToRoom(value);
        }
      },
    );
  }

  Widget _buildStatusCard() {
    final (statusText, statusColor) = switch (_connState) {
      ConnectionState.idle => ('대기 중', const Color(0xFF8b90a4)),
      ConnectionState.connecting => ('연결 중...', const Color(0xFFf0a83a)),
      ConnectionState.connected => (_statusMessage, const Color(0xFF4caf7d)),
      ConnectionState.error => ('오류', const Color(0xFFe05252)),
    };

    final icon = switch (_connState) {
      ConnectionState.idle => Icons.radio_button_unchecked,
      ConnectionState.connecting => Icons.sync,
      ConnectionState.connected => Icons.radio_button_checked,
      ConnectionState.error => Icons.error_outline,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: statusColor.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withAlpha(70)),
      ),
      child: Row(
        children: [
          Icon(icon, color: statusColor, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                color: statusColor,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_connState != ConnectionState.connected) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF131620),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2e3347)),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.desktop_windows_outlined,
                  color: Color(0xFF3a3f58), size: 48),
              SizedBox(height: 12),
              Text(
                '연결되면 미리보기가 표시됩니다',
                style: TextStyle(color: Color(0xFF4a5068), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2e3347)),
      ),
      clipBehavior: Clip.hardEdge,
      child: RTCVideoView(
        _previewRenderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      ),
    );
  }

  Widget _buildDisconnectButton() {
    return OutlinedButton.icon(
      onPressed: () => _disconnect(showEndDialog: true),
      icon: const Icon(Icons.stop_circle_outlined, size: 16),
      label: const Text('연결 종료', style: TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFe05252),
        side: const BorderSide(color: Color(0xFFe05252)),
        padding: const EdgeInsets.symmetric(vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
