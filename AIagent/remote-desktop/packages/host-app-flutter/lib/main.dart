import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show File, Platform;
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'signaling.dart';
import 'peer_manager.dart';
import 'input_handler.dart';
import 'command_executor.dart';
import 'system_diagnostics.dart';
import 'services/chat_service.dart';
import 'screen_recorder.dart';
import 'issue_detector.dart';
import 'diagnostic_runner.dart';

// Win32 윈도우 제어 — Windows에서만 초기화
late final _ShowWindowDart _showWindow;
late final _SetForegroundWindowDart _setForegroundWindow;
late final _FindWindowWDart _findWindowW;

typedef _ShowWindowNative = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);
typedef _SetForegroundWindowNative = Int32 Function(IntPtr hWnd);
typedef _SetForegroundWindowDart = int Function(int hWnd);
typedef _FindWindowWNative = IntPtr Function(Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName);
typedef _FindWindowWDart = int Function(Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName);

void _initWin32() {
  if (!Platform.isWindows) return;
  final user32 = DynamicLibrary.open('user32.dll');
  _showWindow = user32.lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
  _setForegroundWindow = user32.lookupFunction<_SetForegroundWindowNative, _SetForegroundWindowDart>('SetForegroundWindow');
  _findWindowW = user32.lookupFunction<_FindWindowWNative, _FindWindowWDart>('FindWindowW');
}

int _findAppWindow() {
  final title = 'RemoteCall-mini Host'.toNativeUtf16();
  final hwnd = _findWindowW(nullptr, title);
  calloc.free(title);
  return hwnd;
}

void minimizeAppWindow() {
  if (!Platform.isWindows) return;
  final hwnd = _findAppWindow();
  if (hwnd != 0) _showWindow(hwnd, 6); // SW_MINIMIZE = 6
}

void restoreAppWindow() {
  if (!Platform.isWindows) return;
  final hwnd = _findAppWindow();
  if (hwnd != 0) {
    _showWindow(hwnd, 9); // SW_RESTORE = 9
    _setForegroundWindow(hwnd);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _initWin32();
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
    text: 'ws://10.2.107.45:8080',
  );
  final _roomIdController = TextEditingController();

  final _signaling = SignalingClient();
  final _peerManager = PeerManager();
  final _inputHandler = InputHandler();
  final _commandExecutor = CommandExecutor();
  final _diagnostics = SystemDiagnostics();
  final _recorder = ScreenRecorder();
  final _issueDetector = IssueDetector();
  final _runner = DiagnosticRunner();
  Timer? _diagTimer;
  Timer? _fullDiagTimer;

  ConnectionState _connState = ConnectionState.idle;
  String _statusMessage = '대기 중';
  String? _currentRoomId;
  String? _activeViewerId;

  // 채팅 관련 상태
  ChatService? _chatService;
  final List<ChatRoomMessage> _chatHistory = [];
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  // 뷰어가 DataChannel로 전달한 Supabase 세션 UUID (chat_rooms.session_id 필수)
  String? _supabaseSessionId;

  // 스레드 패널 상태
  ChatRoomMessage? _activeThreadMsg;
  final List<ChatRoomMessage> _threadReplies = [];
  final _threadInputController = TextEditingController();
  final _threadScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _setupPeerManagerCallbacks();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _roomIdController.dispose();
    _threadInputController.dispose();
    _threadScrollController.dispose();
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
    _peerManager.onPeerConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _startDiagTimer();
        // 채팅 초기화는 뷰어가 session-info를 보내올 때 시작됨 (_handleControlMessage 참조)
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _disconnect();
      }
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
          // 전환된 모니터의 bounds로 input_handler 업데이트
          final bounds = await _peerManager.getMonitorBounds(int.tryParse(sourceId) ?? 0);
          if (bounds != null) {
            _inputHandler.setActiveBounds(ScreenBounds(
              left: (bounds['x'] as num?)?.toInt() ?? 0,
              top: (bounds['y'] as num?)?.toInt() ?? 0,
              width: (bounds['width'] as num?)?.toInt() ?? 1920,
              height: (bounds['height'] as num?)?.toInt() ?? 1080,
              scaleFactor: (bounds['scaleFactor'] as num?)?.toDouble() ?? 1.0,
            ));
            debugPrint('[control] bounds 업데이트: $bounds');
          }
        }
        return;
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
        return;
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
        return;
      case 'recording-state':
        final recording = msg['recording'] as bool? ?? false;
        debugPrint('[control] recording-state: $recording');
        if (recording) {
          _startHostRecording();
        } else {
          _stopHostRecording();
        }
        return;
      case 'session-info':
        // 뷰어가 발급한 Supabase 세션 UUID 수신 → 채팅 초기화
        final sid = msg['sessionId'] as String? ?? '';
        debugPrint('[control] session-info: sessionId=$sid');
        if (sid.isNotEmpty) {
          _supabaseSessionId = sid;
          _initHostChat();
        }
        return;
      default:
        debugPrint('[control] 처리되지 않은 컨트롤 메시지: $type');
    }
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 20, left: 20, right: 20),
      ),
    );
  }

  Future<void> _connectToRoom(String roomId) async {
    final serverUrl = _serverUrlController.text.trim();
    if (serverUrl.isEmpty) {
      _showErrorDialog('연결 오류', '중계서버 주소를 입력해주세요.\n예: ws://192.168.0.10:8080');
      return;
    }

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
      // password 방식 폐지 — roomId만으로 접속 요청 (뷰어 앱이 승인/거부)
      _signaling.send({
        'type': 'join',
        'roomId': roomId,
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
          minimizeAppWindow();
        }
        return;

      case 'offer':
        final viewerId = msg['viewerId'] as String;
        final sdp = msg['sdp'] as Map<String, dynamic>;
        _handleOffer(viewerId, sdp);
        return;

      case 'ice-candidate':
        final viewerId = msg['viewerId'] as String;
        final candidate = msg['candidate'] as Map<String, dynamic>;
        _peerManager.handleIceCandidate(viewerId, candidate);
        return;

      case 'error':
        final message = msg['message'] as String? ?? '알 수 없는 오류';
        if (mounted) {
          setState(() {
            _connState = ConnectionState.error;
            _statusMessage = '오류: $message';
          });
          _showErrorDialog('연결 실패', '접속번호를 확인하신 후 입력해주세요.');
        }
        return;

      // 자동진단/복구: 승인된 진단 실행 지시
      case 'run.diagnostic':
        _executeDiagnostic(msg);
        return;

      // 자동진단/복구: 승인된 복구 실행 지시
      case 'run.recovery':
        _executeRecovery(msg);
        return;

      case 'abort.operation':
        debugPrint('[signaling] 작업 중단 요청: ${msg['jobId']}');
        // TODO: 실행 중인 작업 중단
        return;

      default:
        return;
    }
  }

  // ── 진단/복구 실행 핸들러 ──────────────────────────────────────

  // 승인 토큰을 서버 REST로 재검증 (보안 이중 방어)
  // 서버에서 이미 검증 후 디스패치하지만, 호스트가 한 번 더 확인
  Future<bool> _validateApprovalToken(String tokenId, String approvalType) async {
    try {
      final serverUrl = _serverUrlController.text.trim()
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://');
      final resp = await http.post(
        Uri.parse('$serverUrl/api/diagnosis/validate-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'tokenId': tokenId, 'approvalType': approvalType}),
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return body['valid'] == true;
      }
    } catch (e) {
      debugPrint('[security] 토큰 검증 실패: $e');
    }
    return false;
  }

  Future<void> _executeDiagnostic(Map<String, dynamic> msg) async {
    final jobId = msg['jobId']?.toString() ?? '';
    final issueId = msg['issueId']?.toString() ?? '';
    final token = msg['approvalToken']?.toString() ?? '';

    // 보안: 승인 토큰 재검증 (누군가 시그널링 WS를 탈취해 위조 메시지를 보내는 경우 방어)
    if (token.isEmpty || !await _validateApprovalToken(token, 'diagnostic')) {
      debugPrint('[security] 진단 토큰 검증 실패 — 실행 거부');
      _showToast('승인 토큰 검증 실패 — 진단 거부');
      return;
    }

    final stepsRaw = (msg['diagnosticSteps'] as List?) ?? [];
    final steps = stepsRaw.map((s) {
      final m = s as Map<String, dynamic>;
      return DiagnosticStep(
        name: m['name']?.toString() ?? '',
        command: m['command']?.toString() ?? '',
        commandType: m['commandType']?.toString() ?? 'cmd',
      );
    }).toList();

    debugPrint('[diagnostic] 실행 시작: job=$jobId, steps=${steps.length}');

    final result = await _runner.runDiagnostic(
      steps: steps,
      onProgress: (stepName, progress) {
        _signaling.send({
          'type': 'diagnostic.progress',
          'jobId': jobId,
          'stepName': stepName,
          'progress': progress,
        });
      },
    );

    // 결과 전송
    _signaling.send({
      'type': 'diagnostic.result',
      'jobId': jobId,
      'issueId': issueId,
      'success': result.success,
      'rootCauseCandidates': result.rootCauseCandidates.map((c) => c.toJson()).toList(),
      'recommendedActions': result.recommendedActions,
      'rawResult': {'steps': result.stepResults.map((s) => s.toJson()).toList()},
    });
  }

  Future<void> _executeRecovery(Map<String, dynamic> msg) async {
    final jobId = msg['jobId']?.toString() ?? '';
    final issueId = msg['issueId']?.toString() ?? '';
    final token = msg['approvalToken']?.toString() ?? '';

    // 보안: 복구 토큰 재검증
    if (token.isEmpty || !await _validateApprovalToken(token, 'recovery')) {
      debugPrint('[security] 복구 토큰 검증 실패 — 실행 거부');
      _showToast('승인 토큰 검증 실패 — 복구 거부');
      return;
    }

    final def = msg['playbookDef'] as Map<String, dynamic>? ?? {};

    debugPrint('[recovery] 실행 시작: job=$jobId');

    final result = await _runner.runPlaybook(
      title: def['title']?.toString() ?? '복구',
      preconditions: (def['preconditions'] as List?)?.cast<Map<String, dynamic>>(),
      actions: ((def['actions'] as List?) ?? []).cast<Map<String, dynamic>>(),
      successCriteria: (def['successCriteria'] as List?)?.cast<Map<String, dynamic>>(),
      rollbackSteps: (def['rollbackSteps'] as List?)?.cast<Map<String, dynamic>>(),
      onProgress: (stepName, progress) {
        _signaling.send({
          'type': 'recovery.progress',
          'jobId': jobId,
          'stepName': stepName,
          'progress': progress,
        });
      },
    );

    _signaling.send({
      'type': 'recovery.result',
      'jobId': jobId,
      'issueId': issueId,
      'success': result['success'] == true,
      'stepResults': result['stepResults'] ?? [],
      'rolledBack': result['rolledBack'] == true,
    });

    // Verification 결과 별도 전송
    final verification = result['verification'] as Map<String, dynamic>?;
    if (verification != null) {
      _signaling.send({
        'type': 'verification.result',
        'jobId': jobId,
        'issueId': issueId,
        'success': verification['success'] == true,
        'criteria': verification['criteria'] ?? [],
      });
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
      _activeViewerId = viewerId;
      await _peerManager.handleOffer(viewerId, sdp);

      // 화면 캡처 스트림을 미리보기 렌더러에 연결
      if (_peerManager.localStream != null && mounted) {
        setState(() => _statusMessage = '뷰어와 연결됨');
      }

      // 최초 캡처 소스의 bounds로 input_handler 초기화
      final initialBounds = await _peerManager.getMonitorBounds(0);
      if (initialBounds != null) {
        _inputHandler.setActiveBounds(ScreenBounds(
          left: (initialBounds['x'] as num?)?.toInt() ?? 0,
          top: (initialBounds['y'] as num?)?.toInt() ?? 0,
          width: (initialBounds['width'] as num?)?.toInt() ?? 1920,
          height: (initialBounds['height'] as num?)?.toInt() ?? 1080,
        ));
        debugPrint('[main] 최초 bounds 설정: $initialBounds');
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

  bool _fullDiagRunning = false;

  void _startDiagTimer() {
    _stopDiagTimer();

    // host-info: 5초마다 (경량 — CPU 부하 최소화)
    _diagTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_peerManager.isConnected) { _stopDiagTimer(); return; }
      try {
        final basic = await _diagnostics.collectBasic();
        _peerManager.sendToViewer({
          'type': 'host-info',
          'info': {
            'os': Platform.operatingSystem,
            'version': (basic['osVersion'] ?? '').toString(),
            'cpuModel': '${Platform.numberOfProcessors} cores',
            'cpuUsage': (basic['cpuUsage'] as num?)?.toInt() ?? 0,
            'memTotal': (basic['totalMemoryMB'] as num?)?.toInt() ?? 0,
            'memUsed': ((basic['totalMemoryMB'] as num?)?.toInt() ?? 0) - ((basic['freeMemoryMB'] as num?)?.toInt() ?? 0),
            'uptime': (basic['uptime'] as num?)?.toInt() ?? 0,
          },
        });
      } catch (e) { debugPrint('[diag] host-info 전송 실패: $e'); }
    });

    // host-diagnostics: 30초마다 (프로세스 수집 제거 — CPU 부하 대폭 감소)
    _fullDiagTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_peerManager.isConnected || _fullDiagRunning) return;
      _fullDiagRunning = true;
      try {
        final diag = await _diagnostics.collect();
        final sys = diag['system'] as Map<String, dynamic>? ?? {};
        final memTotal = (sys['totalMemoryMB'] as num?)?.toInt() ?? 0;
        final memFree = (sys['freeMemoryMB'] as num?)?.toInt() ?? 0;
        final memUsed = memTotal - memFree;
        _peerManager.sendToViewer({
          'type': 'host-diagnostics',
          'diagnostics': {
            'system': {
              'os': Platform.operatingSystem,
              'version': (sys['osVersion'] ?? '').toString(),
              'build': '',
              'pcName': (sys['hostname'] ?? '').toString(),
              'userName': Platform.environment['USERNAME'] ?? '',
              'bootTime': '',
              'uptime': (sys['uptime'] as num?)?.toInt() ?? 0,
              'cpuModel': '${Platform.numberOfProcessors} cores',
              'cpuUsage': (sys['cpuUsage'] as num?)?.toInt() ?? 0,
              'cpuCores': Platform.numberOfProcessors,
              'memTotal': memTotal,
              'memUsed': memUsed,
              'memUsage': memTotal > 0 ? (memUsed * 100 ~/ memTotal) : 0,
              'disks': ((sys['disks'] as List?) ?? []).map((d) {
                final total = double.tryParse((d['totalGB'] ?? '0').toString()) ?? 0;
                final free = double.tryParse((d['freeGB'] ?? '0').toString()) ?? 0;
                final used = total - free;
                return {
                  'drive': d['id'] ?? '',
                  'total': total.round(),
                  'used': used.round(),
                  'usage': total > 0 ? (used / total * 100).round() : 0,
                };
              }).toList(),
              'battery': sys['battery'],
              'isAdmin': false,
            },
            // 프로세스 수집 제거 — wmic 2회 호출 + 1초 딜레이가 성능 병목
            'processes': {'topCpu': <dynamic>[], 'services': <dynamic>[]},
            'network': () {
              final net = diag['network'] as Map<String, dynamic>? ?? {};
              final rawIfaces = (net['interfaces'] as List?) ?? [];
              return {
                'interfaces': rawIfaces.map((i) {
                  final addrs = (i['addresses'] as List?) ?? [];
                  return {'name': i['name'] ?? '', 'ip': addrs.isNotEmpty ? addrs.first : '', 'mac': '', 'type': 'ethernet'};
                }).toList(),
                'gateway': net['gateway'] ?? '',
                'dns': (net['dns'] as List?) ?? [],
                'internetConnected': net['internetAvailable'] ?? false,
                'wifi': net['wifi'],
                'vpnConnected': false,
              };
            }(),
            'security': diag['security'] ?? {'firewallEnabled': false, 'defenderEnabled': false, 'uacEnabled': false, 'antivirusProducts': []},
            'userEnv': diag['userEnv'] ?? {'monitors': [], 'defaultBrowser': '', 'printers': []},
            'recentEvents': diag['recentEvents'] ?? [],
          },
        });

        // ── 이슈 탐지 (PLAN.md Detector 모듈) ────────────────────
        // 수집된 진단 데이터를 Detector로 분석 → 이상 감지 시 시그널링 WS로 전송
        final detectorInput = <String, dynamic>{
          'system': {
            'cpuUsage': (sys['cpuUsage'] as num?)?.toInt() ?? 0,
            'memUsage': memTotal > 0 ? (memUsed * 100 ~/ memTotal) : 0,
            'memUsed': memUsed,
            'memTotal': memTotal,
            'disks': ((sys['disks'] as List?) ?? []).map((d) {
              final total = double.tryParse((d['totalGB'] ?? '0').toString()) ?? 0;
              final free = double.tryParse((d['freeGB'] ?? '0').toString()) ?? 0;
              final used = total - free;
              return {
                'drive': d['id'] ?? '',
                'usage': total > 0 ? (used / total * 100).round() : 0,
              };
            }).toList(),
            'battery': sys['battery'],
          },
          'network': () {
            final net = diag['network'] as Map<String, dynamic>? ?? {};
            return {
              'internetConnected': net['internetAvailable'] ?? false,
              'dns': (net['dns'] as List?) ?? [],
              'gateway': net['gateway'] ?? '',
            };
          }(),
        };
        final detected = _issueDetector.analyze(detectorInput);
        for (final issue in detected) {
          // 시그널링 WS로 이슈 이벤트 전송 → 서버가 DB 저장 + 뷰어에 브로드캐스트
          _signaling.send({
            'type': 'issue.detected',
            'issueId': issue.fingerprint,
            'category': issue.category,
            'severity': issue.severity,
            'summary': issue.summary,
            'detail': issue.detail,
            'metadata': issue.metadata,
          });
        }
      } catch (e) {
        debugPrint('[diag] host-diagnostics 전송 실패: $e');
      } finally {
        _fullDiagRunning = false;
      }
    });
  }

  void _stopDiagTimer() {
    _diagTimer?.cancel();
    _diagTimer = null;
    _fullDiagTimer?.cancel();
    _fullDiagTimer = null;
  }

  // ── 호스트 측 녹화 (FFmpeg gdigrab) ─────────────────────────
  Future<void> _startHostRecording() async {
    final available = await ScreenRecorder.isAvailable();
    if (!available) {
      _showToast('FFmpeg가 설치되어 있지 않아 녹화를 시작할 수 없습니다.');
      // 뷰어에 녹화 실패 알림
      _peerManager.sendToViewer({'type': 'recording-result', 'success': false, 'error': 'FFmpeg not installed'});
      return;
    }
    final ok = await _recorder.start(sessionId: _currentRoomId ?? 'unknown');
    if (ok) {
      _showToast('녹화가 시작되었습니다.');
    } else {
      _showToast('녹화 시작 실패');
      _peerManager.sendToViewer({'type': 'recording-result', 'success': false, 'error': 'start failed'});
    }
  }

  Future<void> _stopHostRecording() async {
    final path = await _recorder.stop();
    if (path == null) {
      _showToast('녹화 파일 없음');
      return;
    }

    _showToast('녹화 중단 — 업로드 중...');

    // 서버에 녹화 파일 업로드
    final serverUrl = _serverUrlController.text.trim()
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');
    final sessionId = _currentRoomId ?? 'unknown';

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverUrl/api/upload-recording'),
      );
      request.fields['sessionId'] = sessionId;
      request.files.add(await http.MultipartFile.fromPath(
        'file', path, filename: '$sessionId.mp4',
      ));

      final response = await request.send().timeout(const Duration(seconds: 120));
      final body = await response.stream.bytesToString();
      debugPrint('[recorder] 업로드 응답: ${response.statusCode} $body');

      if (response.statusCode == 200) {
        final match = RegExp(r'"url"\s*:\s*"([^"]+)"').firstMatch(body);
        final url = match?.group(1);
        if (url != null) {
          // 뷰어에 녹화 완료 + URL 알림
          _peerManager.sendToViewer({'type': 'recording-result', 'success': true, 'url': url});
          _showToast('녹화 파일 업로드 완료');
        }
      } else {
        _showToast('업로드 실패: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[recorder] 업로드 실패: $e');
      _showToast('업로드 오류: $e');
    }
  }

  void _disconnect({bool showEndDialog = false}) {
    _stopDiagTimer();
    _recorder.dispose();
    _chatService = null;
    _chatHistory.clear();
    _activeViewerId = null;
    _supabaseSessionId = null;
    final wasConnected = _connState == ConnectionState.connected;
    if (wasConnected) restoreAppWindow();
    try { _peerManager.close(); } catch (_) {}
    try { _signaling.disconnect(); } catch (_) {}
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
            child: _connState == ConnectionState.connected
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 320, child: _buildConnectPanel()),
                        const SizedBox(width: 16),
                        Expanded(child: _buildHostChatPanel()),
                      ],
                    ),
                  )
                : Center(
                    child: SizedBox(
                      width: 380,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        child: _buildConnectPanel(),
                      ),
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
        hintText: 'ws://서버IP:8080',
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
        // 접속번호 + 인증코드가 모두 6자리이면 자동 연결 시도
        _tryAutoConnect();
      },
    );
  }

  // 접속번호 6자리가 채워지면 바로 연결 시도 (인증코드 불필요)
  void _tryAutoConnect() {
    final roomId = _roomIdController.text.trim();
    if (roomId.length == 6) {
      _connectToRoom(roomId);
    }
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


  // ── 호스트 채팅 패널 ──────────────────────────────────────
  Widget _buildHostChatPanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1e2130),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2e3347)),
      ),
      child: Column(
        children: [
          // 헤더
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF2e3347))),
            ),
            child: const Row(
              children: [
                Text('💬', style: TextStyle(fontSize: 16)),
                SizedBox(width: 8),
                Text('상담 채팅', style: TextStyle(color: Color(0xFFe8eaf0), fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          // 메시지 목록
          Expanded(
            child: _chatHistory.isEmpty
                ? const Center(
                    child: Text('연결된 고객과 채팅이 가능합니다.', style: TextStyle(color: Color(0xFF4a5068), fontSize: 13)),
                  )
                : ListView.builder(
                    controller: _chatScrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _chatHistory.length,
                    itemBuilder: (_, i) => _buildHostChatBubble(_chatHistory[i]),
                  ),
          ),
          // 입력 바
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFF2e3347))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatController,
                    style: const TextStyle(color: Color(0xFFe8eaf0), fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '메시지 입력...',
                      hintStyle: const TextStyle(color: Color(0xFF4a5068), fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF0f1117),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2e3347))),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _sendHostChatMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _sendHostChatMessage,
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(color: const Color(0xFF4f8ef7), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.send, color: Colors.white, size: 16),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 채팅 메시지 버블
  Widget _buildHostChatBubble(ChatRoomMessage msg) {
    final isMe = msg.senderId == 'host';
    final isSystem = msg.senderType == 'system';

    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(child: Text(msg.content, style: const TextStyle(color: Color(0xFF4a5068), fontSize: 11))),
      );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: 6, left: isMe ? 48 : 0, right: isMe ? 0 : 48),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF4f8ef7) : const Color(0xFF2e3347),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(msg.content, style: TextStyle(color: isMe ? Colors.white : const Color(0xFFe8eaf0), fontSize: 13)),
            const SizedBox(height: 3),
            Text(
              '${msg.createdAt.toLocal().hour.toString().padLeft(2, '0')}:${msg.createdAt.toLocal().minute.toString().padLeft(2, '0')}',
              style: TextStyle(color: isMe ? Colors.white70 : const Color(0xFF4a5068), fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  // 호스트 채팅 메시지 전송
  void _sendHostChatMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty || _chatService == null) return;
    // 시그널링 WS로 채팅 메시지 전송
    _signaling.sendChatMessage({
      'type': 'chat-message',
      'chatRoomId': _chatService!.chatRoomId ?? '',
      'senderId': 'host',
      'senderType': 'host',
      'content': text,
    });
    _chatController.clear();
  }

  // 채팅 초기화 (P2P 연결 성공 시 호출)
  Future<void> _initHostChat() async {
    // 뷰어가 DataChannel로 전달한 Supabase 세션 UUID 사용 (chat_rooms.session_id는 UUID 타입)
    final sessionId = _supabaseSessionId;
    final viewerId = _activeViewerId;
    if (sessionId == null || sessionId.isEmpty || viewerId == null || viewerId.isEmpty) {
      debugPrint('[chat] host chat 초기화 건너뜀: sessionId=$sessionId, viewerId=$viewerId');
      return;
    }
    // 이미 초기화됐으면 중복 실행 방지
    if (_chatService?.chatRoomId != null) return;

    final serverUrl = _serverUrlController.text.trim()
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://');

    _chatService = ChatService(serverUrl: serverUrl, userId: 'host', userType: 'host');

    final roomId = await _chatService!.createOrJoinRoom(
      sessionId,
      ['host', viewerId],
    );
    if (roomId != null) {
      _chatService!.chatRoomId = roomId;
      final msgs = await _chatService!.loadMessages();
      if (mounted) {
        setState(() {
          _chatHistory
            ..clear()
            ..addAll(msgs);
        });
      }
    }

    // WS 브로드캐스트 수신 연결
    _signaling.onChatMessage = (msg) {
      _chatService?.handleIncomingWsMessage(msg);
    };

    _chatService!.onMessage = (msg) {
      if (!mounted) return;

      if (msg.parentMessageId != null) {
        // 답글: 부모 메시지의 replyCount +1 갱신
        setState(() {
          final idx = _chatHistory.indexWhere((m) => m.id == msg.parentMessageId);
          if (idx >= 0) {
            _chatHistory[idx] = _chatHistory[idx].copyWith(
              replyCount: _chatHistory[idx].replyCount + 1,
            );
          }
          // 같은 스레드가 열려 있으면 답글 목록에 추가
          if (_activeThreadMsg?.id == msg.parentMessageId) {
            _threadReplies.add(msg);
          }
        });
        // 스레드 패널 자동 스크롤
        if (_activeThreadMsg?.id == msg.parentMessageId) {
          Future.delayed(const Duration(milliseconds: 50), () {
            if (_threadScrollController.hasClients) {
              _threadScrollController.jumpTo(_threadScrollController.position.maxScrollExtent);
            }
          });
        }
      } else {
        // 일반 메시지: 메인 채팅에 추가
        setState(() => _chatHistory.add(msg));
        Future.delayed(const Duration(milliseconds: 50), () {
          if (_chatScrollController.hasClients) {
            _chatScrollController.jumpTo(_chatScrollController.position.maxScrollExtent);
          }
        });
      }
    };
  }

  // 스레드 패널 열기
  void _openHostThreadPanel(ChatRoomMessage msg) {
    setState(() {
      _activeThreadMsg = msg;
      _threadReplies.clear();
    });
    _chatService?.loadReplies(msg.id).then((replies) {
      if (!mounted) return;
      setState(() => _threadReplies.addAll(replies));
      Future.delayed(const Duration(milliseconds: 50), () {
        if (_threadScrollController.hasClients) {
          _threadScrollController.jumpTo(_threadScrollController.position.maxScrollExtent);
        }
      });
    });
  }

  // 스레드 패널 닫기
  void _closeHostThreadPanel() {
    setState(() {
      _activeThreadMsg = null;
      _threadReplies.clear();
    });
  }

  // 스레드 답글 전송
  void _sendHostThreadReply() {
    final text = _threadInputController.text.trim();
    if (text.isEmpty || _chatService == null || _activeThreadMsg == null) return;
    _signaling.sendChatMessage({
      'type': 'chat-message',
      'chatRoomId': _chatService!.chatRoomId ?? '',
      'senderId': 'host',
      'senderType': 'host',
      'content': text,
      'messageType': 'text',
      'parentMessageId': _activeThreadMsg!.id,
    });
    _threadInputController.clear();
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
