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
      if (event.streams.isNotEmpty) {
        onTrack?.call(event.streams.first);
      }
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

    final offer = await _pc!.createOffer({
      'offerToReceiveVideo': true,
      'offerToReceiveAudio': false,
    });
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
