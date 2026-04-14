import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class PeerManager {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;

  // DataChannel 연결 후 화면 소스 목록 전송을 위해 저장
  List<DesktopCapturerSource> _capturedSources = [];
  String _activeSourceId = '';

  // 마우스/키보드 입력 메시지 (mousemove, keydown 등)
  Function(Map<String, dynamic>)? onDataChannelMessage;
  // 컨트롤 메시지 (source-changed, execute-macro 등 입력 제어 외 메시지)
  Function(Map<String, dynamic>)? onControlMessage;
  Function(RTCPeerConnectionState state)? onPeerConnectionState;
  Function(RTCIceCandidate candidate, String viewerId)? onIceCandidate;
  Function(RTCSessionDescription answer, String viewerId)? onAnswerReady;

  // DataChannel 메시지를 입력 타입과 컨트롤 타입으로 분류
  static const _inputTypes = {
    'mousemove', 'mousedown', 'mouseup', 'scroll',
    'keydown', 'keyup', 'text-input', 'clipboard-sync',
  };

  Future<void> handleOffer(
    String viewerId,
    Map<String, dynamic> sdpMap,
  ) async {
    await _initPeerConnection(viewerId);

    final offer = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
    await _pc!.setRemoteDescription(offer);

    // 화면 캡처 시작 후 트랙 추가
    _localStream = await startScreenCapture();
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
    }

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);

    // 비디오 비트레이트 2.5Mbps로 제한 — 대역폭 절약 + 지연 감소
    await _applyBitrateLimit();

    onAnswerReady?.call(answer, viewerId);
  }

  Future<void> handleIceCandidate(
    String viewerId,
    Map<String, dynamic> candidateMap,
  ) async {
    if (_pc == null) return;

    final candidate = RTCIceCandidate(
      candidateMap['candidate'],
      candidateMap['sdpMid'],
      candidateMap['sdpMLineIndex'],
    );
    await _pc!.addCandidate(candidate);
  }

  Future<MediaStream?> startScreenCapture() async {
    try {
      final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
      if (sources.isEmpty) {
        debugPrint('[peer] 사용 가능한 화면 소스 없음');
        return null;
      }
      final source = sources.first;
      debugPrint('[peer] 화면 소스: ${source.name} (${source.id})');

      // DataChannel onOpen 시 소스 목록 전송을 위해 저장
      _capturedSources = sources;
      _activeSourceId = source.id;

      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': source.id},
          'mandatory': {
            'chromeMediaSource': 'desktop',
            'chromeMediaSourceId': source.id,
            'frameRate': 30,
          },
        },
        'audio': false,
      });
      return stream;
    } catch (e) {
      debugPrint('[peer] 화면 캡처 시작 실패: $e');
      return null;
    }
  }

  // 모니터 bounds 캐시 (PowerShell 1회만 실행)
  List<Map<String, dynamic>>? _monitorBoundsCache;

  Future<Map<String, dynamic>?> getMonitorBounds(int index) async {
    if (Platform.isMacOS) return null;

    if (_monitorBoundsCache != null) {
      return index < _monitorBoundsCache!.length ? _monitorBoundsCache![index] : null;
    }

    try {
      // DPI-unaware 모드: Screen.Bounds가 물리적 해상도 반환
      final r = await Process.run('powershell', [
        '-NoProfile', '-Command',
        r"Add-Type -AssemblyName System.Windows.Forms; "
        r"foreach($s in [System.Windows.Forms.Screen]::AllScreens) { "
        r"  $b = $s.Bounds; "
        r"  Write-Output ('{0},{1},{2},{3}' -f $b.X, $b.Y, $b.Width, $b.Height) "
        r"}"
      ], runInShell: true).timeout(const Duration(seconds: 5));

      final lines = r.stdout.toString().split('\n')
          .map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

      _monitorBoundsCache = lines.map((line) {
        final p = line.split(',');
        if (p.length >= 4) {
          return <String, dynamic>{
            'x': int.tryParse(p[0].trim()) ?? 0,
            'y': int.tryParse(p[1].trim()) ?? 0,
            'width': int.tryParse(p[2].trim()) ?? 1920,
            'height': int.tryParse(p[3].trim()) ?? 1080,
            'scaleFactor': 1.0,
          };
        }
        return <String, dynamic>{'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'scaleFactor': 1.0};
      }).toList();

      debugPrint('[peer] 모니터 bounds 캐시: $_monitorBoundsCache');
      return index < _monitorBoundsCache!.length ? _monitorBoundsCache![index] : null;
    } catch (e) {
      debugPrint('[peer] 모니터 bounds 조회 실패: $e');
    }
    return null;
  }

  Future<void> switchSource(String sourceId) async {
    if (_activeSourceId == sourceId && _localStream != null) {
      final source = _capturedSources.where((s) => s.id == sourceId).firstOrNull;
      if (source != null) {
        final bounds = await getMonitorBounds(int.tryParse(sourceId) ?? 0);
        sendToViewer({
          'type': 'source-changed', 'sourceId': source.id, 'name': source.name,
          if (bounds != null) 'bounds': bounds,
        });
      }
      return;
    }

    try {
      final source = _capturedSources.where((s) => s.id == sourceId).firstOrNull;
      if (source == null) {
        debugPrint('[peer] 소스를 찾을 수 없음: $sourceId');
        return;
      }

      final newStream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': source.id},
          'mandatory': {
            'chromeMediaSource': 'desktop',
            'chromeMediaSourceId': source.id,
            'frameRate': 30,
          },
        },
        'audio': false,
      });

      // 기존 트랙 교체
      final newTrack = newStream.getVideoTracks().first;
      final senders = await _pc!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await sender.replaceTrack(newTrack);
          break;
        }
      }

      _localStream?.getTracks().forEach((t) => t.stop());
      _localStream?.dispose();
      _localStream = newStream;
      _activeSourceId = sourceId;

      final bounds = await getMonitorBounds(int.tryParse(sourceId) ?? 0);
      sendToViewer({
        'type': 'source-changed', 'sourceId': source.id, 'name': source.name,
        if (bounds != null) 'bounds': bounds,
      });
      debugPrint('[peer] 소스 전환 완료: ${source.name} bounds=$bounds');
    } catch (e) {
      debugPrint('[peer] 소스 전환 실패: $e');
    }
  }

  // 비디오 비트레이트를 2.5Mbps로 제한
  Future<void> _applyBitrateLimit() async {
    if (_pc == null) return;
    try {
      final senders = await _pc!.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          final params = sender.parameters;
          if (params.encodings != null && params.encodings!.isNotEmpty) {
            params.encodings!.first.maxBitrate = 2500000;
            await sender.setParameters(params);
            debugPrint('[peer] 비트레이트 제한 설정: 2.5Mbps');
          }
        }
      }
    } catch (e) {
      debugPrint('[peer] 비트레이트 설정 실패: $e');
    }
  }

  void sendToViewer(Map<String, dynamic> msg) {
    if (_dc == null || _dc!.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    final type = msg['type'] ?? '';
    _dc!.send(RTCDataChannelMessage(jsonEncode(msg)));
    if (type == 'host-info' || type == 'host-diagnostics') {
      debugPrint('[peer] 전송: $type');
    }
  }

  void close() {
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _dc?.close();
    _pc?.close();
    _pc = null;
    _dc = null;
    _localStream = null;
    _capturedSources = [];
    _activeSourceId = '';
    _monitorBoundsCache = null;
  }

  MediaStream? get localStream => _localStream;

  bool get isConnected =>
      _dc != null && _dc!.state == RTCDataChannelState.RTCDataChannelOpen;

  Future<void> _initPeerConnection(String viewerId) async {
    // 기존 연결이 있으면 먼저 정리
    if (_pc != null) close();

    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    // 뷰어와 동일한 설정으로 DataChannel 생성 (negotiated: true, id: 0)
    final dcInit = RTCDataChannelInit()
      ..negotiated = true
      ..id = 0
      ..ordered = true;
    _dc = await _pc!.createDataChannel('input', dcInit);

    _dc!.onDataChannelState = (RTCDataChannelState state) async {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        debugPrint('[peer] DataChannel 열림 — 화면 소스 목록 전송');
        sendToViewer({
          'type': 'screen-sources',
          'sources': _capturedSources
              .map((s) => {'id': s.id, 'name': s.name})
              .toList(),
          'activeSourceId': _activeSourceId,
        });
        // 활성 소스의 bounds도 전송
        final activeSrc = _capturedSources.where((s) => s.id == _activeSourceId).firstOrNull;
        if (activeSrc != null) {
          final bounds = await getMonitorBounds(int.tryParse(_activeSourceId) ?? 0);
          sendToViewer({
            'type': 'source-changed', 'sourceId': activeSrc.id, 'name': activeSrc.name,
            if (bounds != null) 'bounds': bounds,
          });
        }
      }
    };

    _dc!.onMessage = (RTCDataChannelMessage message) {
      try {
        final msg = jsonDecode(message.text) as Map<String, dynamic>;
        final type = msg['type'] as String?;
        debugPrint('[peer] DC 수신: $type');
        if (type != null && _inputTypes.contains(type)) {
          onDataChannelMessage?.call(msg);
        } else {
          debugPrint('[peer] → onControlMessage: $type');
          onControlMessage?.call(msg);
        }
      } catch (e) {
        debugPrint('[peer] DataChannel 메시지 파싱 오류: $e');
      }
    };

    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null) {
        onIceCandidate?.call(candidate, viewerId);
      }
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[peer] 연결 상태 변경: $state');
      onPeerConnectionState?.call(state);
    };
  }
}
