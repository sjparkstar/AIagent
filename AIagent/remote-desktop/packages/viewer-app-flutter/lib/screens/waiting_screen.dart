import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../signaling.dart';
import 'streaming_screen.dart';

class WaitingScreen extends StatefulWidget {
  final String serverUrl;

  const WaitingScreen({super.key, required this.serverUrl});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  final _signaling = ViewerSignaling();

  String? _roomId;
  String _statusMessage = '서버에 연결 중...';
  bool _connecting = true;
  bool _hostJoined = false;
  // 승인 다이얼로그 중복 표시 방지
  bool _approvalDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _startWaiting();
  }

  @override
  void dispose() {
    if (!_hostJoined) {
      _signaling.disconnect();
    }
    super.dispose();
  }

  Future<void> _startWaiting() async {
    _signaling.onHostReady = (roomId) {
      if (mounted) {
        setState(() {
          _roomId = roomId;
          _statusMessage = '호스트 대기 중...';
          _connecting = false;
        });
      }
    };

    _signaling.onViewerJoined = (viewerId) {
      if (mounted) {
        setState(() {
          _hostJoined = true;
          _statusMessage = '호스트가 연결되었습니다.';
        });
        _navigateToStreaming(viewerId);
      }
    };

    _signaling.onError = (code, message) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _statusMessage = '오류: $message';
        });
      }
    };

    _signaling.onDisconnected = () {
      if (mounted && !_hostJoined) {
        setState(() {
          _connecting = false;
          _statusMessage = '연결이 끊어졌습니다.';
        });
      }
    };

    // 호스트 앱이 접속 요청을 보내면 승인 다이얼로그 표시
    _signaling.onHostJoinRequest = (viewerId) {
      _showApprovalDialog(viewerId);
    };

    try {
      await _signaling.connect(widget.serverUrl);
      _signaling.register();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _statusMessage = '연결 실패: $e';
        });
      }
    }
  }

  void _navigateToStreaming(String viewerId) {
    final roomId = _roomId ?? '';
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => StreamingScreen(
          serverUrl: widget.serverUrl,
          roomId: roomId,
          viewerId: viewerId,
          signaling: _signaling,
        ),
      ),
    );
  }

  void _cancel() {
    _signaling.disconnect();
    Navigator.of(context).pop();
  }

  // 호스트 접속 요청 승인 다이얼로그
  Future<void> _showApprovalDialog(String viewerId) async {
    if (!mounted || _approvalDialogOpen) return;
    _approvalDialogOpen = true;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: bgCard,
        title: const Text('호스트 접속 요청',
            style: TextStyle(color: textPrimary, fontSize: 15)),
        content: const Text(
          '원격지원 호스트가 접속을 요청했습니다.\n승인하시겠습니까?',
          style: TextStyle(color: textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('거부', style: TextStyle(color: danger)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('승인', style: TextStyle(color: accent)),
          ),
        ],
      ),
    );
    _approvalDialogOpen = false;
    final approved = result ?? false;
    _signaling.sendApproveHost(viewerId, approved);
    if (!approved && mounted) {
      setState(() => _statusMessage = '호스트 접속을 거부했습니다. 다시 대기 중...');
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
            child: Center(
              child: Container(
                width: 360,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: bgCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_connecting || (_roomId != null && !_hostJoined))
                      const SizedBox(
                        width: 48,
                        height: 48,
                        child: CircularProgressIndicator(
                          color: accent,
                          strokeWidth: 3,
                        ),
                      )
                    else
                      Icon(
                        _hostJoined
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        color: _hostJoined ? success : danger,
                        size: 48,
                      ),
                    const SizedBox(height: 24),
                    if (_roomId != null) ...[
                      const Text(
                        '접속번호',
                        style: TextStyle(color: textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _roomId!,
                        style: const TextStyle(
                          color: accent,
                          fontSize: 40,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '호스트에게 이 번호를 알려주세요.',
                        style: TextStyle(color: textSecondary, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '호스트가 접속을 시도하면 승인 여부를 묻습니다.',
                        style: TextStyle(color: textSecondary, fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                    ],
                    Text(
                      _statusMessage,
                      style: const TextStyle(
                        color: textPrimary,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _cancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: danger,
                          side: const BorderSide(color: danger),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('대기 취소'),
                      ),
                    ),
                  ],
                ),
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
          IconButton(
            icon: const Icon(Icons.arrow_back, color: textSecondary, size: 20),
            onPressed: _cancel,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 12),
          const Text(
            '상담 대기',
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
}
