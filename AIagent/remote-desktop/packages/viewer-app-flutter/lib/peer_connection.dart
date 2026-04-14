import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class ViewerPeerConnection {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  String? _viewerId;

  Function(MediaStream stream)? onTrack;
  Function(RTCDataChannel channel)? onChannelOpen;
  Function(RTCPeerConnectionState state)? onConnectionState;
  Function(Map<String, dynamic> msg)? onControlMessage;
  Function(RTCIceCandidate candidate)? onIceCandidate;
  Function(RTCSessionDescription offer)? onOfferReady;

  bool get isOpen =>
      _dc != null && _dc!.state == RTCDataChannelState.RTCDataChannelOpen;

  Future<void> initialize() async {
    _pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });

    final dcInit = RTCDataChannelInit()
      ..negotiated = true
      ..id = 0
      ..ordered = true;
    _dc = await _pc!.createDataChannel('input', dcInit);

    _dc!.onDataChannelState = (RTCDataChannelState state) {
      debugPrint('[peer] DataChannel 상태: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onChannelOpen?.call(_dc!);
      }
    };

    _dc!.onMessage = (RTCDataChannelMessage message) {
      try {
        final msg = jsonDecode(message.text) as Map<String, dynamic>;
        onControlMessage?.call(msg);
      } catch (e) {
        debugPrint('[peer] DataChannel 메시지 파싱 오류: $e');
      }
    };

    _pc!.onTrack = (RTCTrackEvent event) {
      debugPrint('[peer] onTrack 이벤트: streams=${event.streams.length}');
      if (event.streams.isNotEmpty) {
        onTrack?.call(event.streams.first);
      }
    };

    // Windows 데스크톱에서는 onTrack 대신 onAddStream이 호출될 수 있음
    _pc!.onAddStream = (MediaStream stream) {
      debugPrint('[peer] onAddStream 이벤트: id=${stream.id}');
      onTrack?.call(stream);
    };

    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        onIceCandidate?.call(candidate);
      }
    };

    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[peer] 연결 상태: $state');
      onConnectionState?.call(state);
    };
  }

  Future<void> startOffer(String viewerId) async {
    _viewerId = viewerId;
    if (_pc == null) await initialize();

    // 웹 뷰어와 동일하게 recvonly 트랜시버를 명시적으로 추가
    // (offerToReceiveVideo 제약 대신 트랜시버 기반으로 SDP 협상)
    await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    onOfferReady?.call(offer);
  }

  Future<void> setAnswer(Map<String, dynamic> sdpMap) async {
    if (_pc == null) return;
    final answer = RTCSessionDescription(sdpMap['sdp'], sdpMap['type']);
    await _pc!.setRemoteDescription(answer);
  }

  Future<void> addIceCandidate(Map<String, dynamic> candidateMap) async {
    if (_pc == null) return;
    final candidate = RTCIceCandidate(
      candidateMap['candidate'],
      candidateMap['sdpMid'],
      candidateMap['sdpMLineIndex'],
    );
    await _pc!.addCandidate(candidate);
  }

  void sendMessage(Map<String, dynamic> msg) {
    if (!isOpen) {
      debugPrint('[peer] DataChannel 닫혀 있음, 전송 무시');
      return;
    }
    _dc!.send(RTCDataChannelMessage(jsonEncode(msg)));
  }

  void close() {
    _dc?.close();
    _pc?.close();
    _dc = null;
    _pc = null;
    _viewerId = null;
  }

  String? get viewerId => _viewerId;
}
