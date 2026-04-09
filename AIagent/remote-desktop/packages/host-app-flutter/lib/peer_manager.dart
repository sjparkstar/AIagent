import 'dart:convert';
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

  Future<void> switchSource(String sourceId) async {
    if (_activeSourceId == sourceId && _localStream != null) {
      // 같은 소스: source-changed만 재전송
      final source = _capturedSources.where((s) => s.id == sourceId).firstOrNull;
      if (source != null) {
        sendToViewer({'type': 'source-changed', 'sourceId': source.id, 'name': source.name});
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

      sendToViewer({'type': 'source-changed', 'sourceId': source.id, 'name': source.name});
      debugPrint('[peer] 소스 전환 완료: ${source.name}');
    } catch (e) {
      debugPrint('[peer] 소스 전환 실패: $e');
    }
  }

  void sendToViewer(Map<String, dynamic> msg) {
    if (_dc == null || _dc!.state != RTCDataChannelState.RTCDataChannelOpen) {
      debugPrint('[peer] DataChannel 미연결 상태에서 전송 시도 무시');
      return;
    }
    _dc!.send(RTCDataChannelMessage(jsonEncode(msg)));
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

    _dc!.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        debugPrint('[peer] DataChannel 열림 — 화면 소스 목록 전송');
        sendToViewer({
          'type': 'screen-sources',
          'sources': _capturedSources
              .map((s) => {'id': s.id, 'name': s.name})
              .toList(),
          'activeSourceId': _activeSourceId,
        });
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
    };
  }
}
