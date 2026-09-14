import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'websocket_service.dart';

/// Manages WebRTC peer connections for audio/video calls.
///
/// Key features:
/// - Echo cancellation (AEC) — prevents feedback loops
/// - Noise suppression (NS) — filters background noise
/// - Automatic gain control (AGC) — consistent volume levels
/// - High-priority audio codec (Opus at 48kHz)
/// - Real-time quality diagnostics
/// - Speaker detection
class WebRTCService {
  WebRTCService._();

  static final WebRTCService instance = WebRTCService._();

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  String? _currentCallId;
  bool _isMuted = false;
  bool _isSpeakerOn = false;

  // Diagnostics
  Timer? _diagnosticsTimer;
  final _diagnosticsController = StreamController<CallDiagnostics>.broadcast();
  final _callStateController = StreamController<CallState>.broadcast();
  final _speakerController = StreamController<SpeakerInfo>.broadcast();

  /// Real-time call diagnostics (jitter, packet loss, RTT, etc.).
  Stream<CallDiagnostics> get diagnostics => _diagnosticsController.stream;

  /// Call state changes.
  Stream<CallState> get callState => _callStateController.stream;

  /// Speaker detection updates.
  Stream<SpeakerInfo> get speakerInfo => _speakerController.stream;

  bool get isInCall => _currentCallId != null;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  // ─────────────────── ICE Servers ───────────────────

  /// Google STUN servers + Metered TURN (injected from config).
  List<Map<String, String>> _iceServers = [];

  /// Configures ICE servers (STUN + TURN).
  void configureIceServers({
    required List<Map<String, String>> turnServers,
    List<Map<String, String>> stunServers = const [],
  }) {
    // Always include Google's public STUN servers as fallback.
    const googleStun = [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
    ];

    _iceServers = [
      ...turnServers,
      ...stunServers,
      ...googleStun,
    ];

    debugPrint('[Athur][webrtc] ICE servers configured: ${_iceServers.length} servers');
  }

  // ─────────────────── Call Lifecycle ───────────────────

  /// Starts an outgoing call.
  Future<void> startCall({
    required String callId,
    required String targetUserId,
    bool videoEnabled = false,
  }) async {
    _currentCallId = callId;
    _callStateController.add(CallState(
      status: CallStatus.calling,
      callId: callId,
      isVideo: videoEnabled,
    ));

    await _setupLocalStream(audioOnly: !videoEnabled);
    await _createPeerConnection();

    // Create offer.
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    // Send offer via WebSocket.
    await WebSocketService.instance.sendCallSignal(
      callId: callId,
      signalType: 'offer',
      data: offer.toMap(),
    );

    _startDiagnostics();
  }

  /// Handles incoming call offer.
  Future<void> handleOffer({
    required String callId,
    required Map<String, Object?> offerData,
  }) async {
    _currentCallId = callId;
    _callStateController.add(CallState(
      status: CallStatus.receiving,
      callId: callId,
    ));

    await _setupLocalStream(audioOnly: true);
    await _createPeerConnection();

    final offer = RTCSessionDescription(
      offerData['sdp'] as String,
      offerData['type'] as String,
    );
    await _peerConnection!.setRemoteDescription(offer);

    // Create answer.
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    // Send answer via WebSocket.
    await WebSocketService.instance.sendCallSignal(
      callId: callId,
      signalType: 'answer',
      data: answer.toMap(),
    );

    _callStateController.add(CallState(
      status: CallStatus.connected,
      callId: callId,
    ));

    _startDiagnostics();
  }

  /// Handles call answer.
  Future<void> handleAnswer({
    required String callId,
    required Map<String, Object?> answerData,
  }) async {
    final answer = RTCSessionDescription(
      answerData['sdp'] as String,
      answerData['type'] as String,
    );
    await _peerConnection!.setRemoteDescription(answer);

    _callStateController.add(CallState(
      status: CallStatus.connected,
      callId: callId,
    ));
  }

  /// Handles ICE candidate.
  Future<void> handleIceCandidate({
    required String callId,
    required Map<String, Object?> candidateData,
  }) async {
    final candidate = RTCIceCandidate(
      candidateData['candidate'] as String,
      candidateData['sdpMid'] as String?,
      candidateData['sdpMLineIndex'] as int?,
    );
    await _peerConnection!.addCandidate(candidate);
  }

  /// Ends the current call.
  Future<void> endCall() async {
    _diagnosticsTimer?.cancel();

    // Send hangup signal.
    if (_currentCallId != null) {
      await WebSocketService.instance.sendCallSignal(
        callId: _currentCallId!,
        signalType: 'hangup',
        data: {},
      );
    }

    await _cleanup();
    _callStateController.add(CallState(
      status: CallStatus.ended,
      callId: _currentCallId ?? '',
    ));
    _currentCallId = null;
  }

  // ─────────────────── Audio Controls ───────────────────

  /// Toggles microphone mute.
  Future<void> toggleMute() async {
    if (_localStream == null) return;
    _isMuted = !_isMuted;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    debugPrint('[Athur][webrtc] Mute: $_isMuted');
  }

  /// Toggles speaker (loudspeaker vs earpiece).
  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    await Helper.setSpeakerphoneOn(_isSpeakerOn);
    debugPrint('[Athur][webrtc] Speaker: $_isSpeakerOn');
    _speakerController.add(SpeakerInfo(isLoudspeaker: _isSpeakerOn));
  }

  // ─────────────────── Diagnostics ───────────────────

  void _startDiagnostics() {
    _diagnosticsTimer?.cancel();
    _diagnosticsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _collectDiagnostics();
    });
  }

  Future<void> _collectDiagnostics() async {
    if (_peerConnection == null) return;

    try {
      final stats = await _peerConnection!.getStats();
      final diagnostics = _parseStats(stats);
      _diagnosticsController.add(diagnostics);

      // Detect active speaker from audio levels.
      _detectSpeaker(stats);
    } catch (e) {
      debugPrint('[Athur][webrtc] Diagnostics error: $e');
    }
  }

  CallDiagnostics _parseStats(List<StatsReport> stats) {
    int bytesReceived = 0;
    int bytesSent = 0;
    int packetsLost = 0;
    int packetsReceived = 0;
    double jitter = 0;
    int roundTripTime = 0;
    String codec = '';
    int audioLevel = 0;

    for (final report in stats) {
      final values = report.values;

      if (report.type == 'inbound-rtp' || report.type == 'ssrc') {
        bytesReceived += _toInt(values['bytesReceived']);
        packetsReceived += _toInt(values['packetsReceived']);
        packetsLost += _toInt(values['packetsLost']);
        jitter = _toDouble(values['jitter'] ?? 0);
        audioLevel = _toInt(values['audioLevel'] ?? 0);

        if (values['kind'] == 'audio' || values['mediaType'] == 'audio') {
          codec = values['codecId'] as String? ?? 'opus';
        }
      }

      if (report.type == 'outbound-rtp' || report.type == 'ssrc') {
        bytesSent += _toInt(values['bytesSent']);
      }

      if (report.type == 'candidate-pair' && values['state'] == 'succeeded') {
        roundTripTime = _toInt(values['currentRoundTripTime'] ?? 0);
      }
    }

    // Calculate packet loss percentage.
    final totalPackets = packetsReceived + packetsLost;
    final lossPercentage = totalPackets > 0
        ? (packetsLost / totalPackets * 100)
        : 0.0;

    return CallDiagnostics(
      bytesReceived: bytesReceived,
      bytesSent: bytesSent,
      packetsLost: packetsLost,
      packetsReceived: packetsReceived,
      lossPercentage: lossPercentage,
      jitter: jitter,
      roundTripTimeMs: roundTripTime,
      codec: codec,
      audioLevel: audioLevel,
      timestamp: DateTime.now(),
    );
  }

  void _detectSpeaker(List<StatsReport> stats) {
    for (final report in stats) {
      final values = report.values;
      if (report.type == 'media-source' &&
          (values['kind'] == 'audio' || values['mediaType'] == 'audio')) {
        final audioLevel = _toInt(values['audioLevel'] ?? 0);
        final totalAudioEnergy = _toDouble(values['totalAudioEnergy'] ?? 0);

        _speakerController.add(SpeakerInfo(
          isLoudspeaker: _isSpeakerOn,
          audioLevel: audioLevel,
          totalEnergy: totalAudioEnergy,
          isSpeaking: audioLevel > 100,
        ));
      }
    }
  }

  // ─────────────────── Private Helpers ───────────────────

  Future<void> _setupLocalStream({required bool audioOnly}) async {
    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
        'sampleRate': 48000,
        'channelCount': 1,
        'latency': 0.01,
        'jitterBuffer': true,
        'jitterBufferMaxLatency': 30,
        'jitterBufferMinLatency': 0,
        'jitterBufferMaxBurst': 30,
        'jitterBufferMinBurst': 0,
        'jitterBufferTarget': 50,
        'jitterBufferLowerBound': 0,
        'jitterBufferUpperBound': 500,
        'jitterBufferMinimumDelay': 0,
        'jitterBufferMaximumDelay': 500,
        'jitterBufferAcceleration': 0,
        'jitterBufferDeceleration': 0,
      },
      'video': !audioOnly,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    debugPrint('[Athur][webrtc] Local stream: audio=${_localStream!.getAudioTracks().length}, video=${_localStream!.getVideoTracks().length}');
  }

  Future<void> _createPeerConnection() async {
    final config = <String, dynamic>{
      'iceServers': _iceServers,
      'sdpSemantics': 'plan-b',
      'iceCandidatePoolSize': 10,
      // Audio quality optimizations.
      'encodedInsertableStreams': false,
    };

    _peerConnection = await createPeerConnection(config);

    // Add local tracks.
    _localStream?.getTracks().forEach((track) async {
      if (track.kind == 'audio') {
        await _peerConnection!.addTrack(track, _localStream!);
      }
    });

    // Handle remote tracks.
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio') {
        _remoteStream = event.streams.first;
        debugPrint('[Athur][webrtc] Remote audio track received');
      }
    };

    // Handle ICE candidates.
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) async {
      if (_currentCallId != null) {
        await WebSocketService.instance.sendCallSignal(
          callId: _currentCallId!,
          signalType: 'ice_candidate',
          data: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        );
      }
    };

    // Connection state changes.
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('[Athur][webrtc] Connection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        endCall();
      }
    };
  }

  Future<void> _cleanup() async {
    _diagnosticsTimer?.cancel();

    // Stop local tracks.
    _localStream?.getTracks().forEach((track) async {
      await track.stop();
    });
    await _localStream?.dispose();
    _localStream = null;

    // Close peer connection.
    await _peerConnection?.close();
    _peerConnection = null;

    _remoteStream = null;
    _isMuted = false;
    _isSpeakerOn = false;
  }

  int _toInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    return 0;
  }

  double _toDouble(Object? value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return 0;
  }
}

/// Call state.
class CallState {
  const CallState({
    required this.status,
    required this.callId,
    this.isVideo = false,
  });

  final CallStatus status;
  final String callId;
  final bool isVideo;
}

enum CallStatus { calling, receiving, connected, ended }

/// Real-time call diagnostics.
class CallDiagnostics {
  const CallDiagnostics({
    required this.bytesReceived,
    required this.bytesSent,
    required this.packetsLost,
    required this.packetsReceived,
    required this.lossPercentage,
    required this.jitter,
    required this.roundTripTimeMs,
    required this.codec,
    required this.audioLevel,
    required this.timestamp,
  });

  final int bytesReceived;
  final int bytesSent;
  final int packetsLost;
  final int packetsReceived;
  final double lossPercentage;
  final double jitter;
  final int roundTripTimeMs;
  final String codec;
  final int audioLevel;
  final DateTime timestamp;

  /// Quality rating based on metrics.
  CallQuality get quality {
    if (lossPercentage > 10 || jitter > 50 || roundTripTimeMs > 300) {
      return CallQuality.critical;
    }
    if (lossPercentage > 5 || jitter > 30 || roundTripTimeMs > 200) {
      return CallQuality.poor;
    }
    if (lossPercentage > 2 || jitter > 15 || roundTripTimeMs > 100) {
      return CallQuality.fair;
    }
    if (lossPercentage > 0.5 || jitter > 5 || roundTripTimeMs > 50) {
      return CallQuality.good;
    }
    return CallQuality.excellent;
  }

  String get formattedBitrate {
    final kbps = (bytesReceived * 8) / 1000;
    if (kbps > 1000) return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
    return '${kbps.toStringAsFixed(0)} kbps';
  }

  @override
  String toString() => 'Diagnostics(bitrate: $formattedBitrate, '
      'loss: ${lossPercentage.toStringAsFixed(1)}%, '
      'jitter: ${jitter.toStringAsFixed(1)}ms, '
      'rtt: ${roundTripTimeMs}ms, '
      'quality: $quality)';
}

enum CallQuality { excellent, good, fair, poor, critical }

/// Speaker detection info.
class SpeakerInfo {
  const SpeakerInfo({
    required this.isLoudspeaker,
    this.audioLevel = 0,
    this.totalEnergy = 0,
    this.isSpeaking = false,
  });

  final bool isLoudspeaker;
  final int audioLevel;
  final double totalEnergy;
  final bool isSpeaking;
}
