import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/call_ringtone_service.dart';
import '../../../core/services/webrtc_service.dart';
import '../../../core/theme/athur_colors.dart';

/// Active call screen with real-time diagnostics overlay.
///
/// Shows:
/// - Remote user's name/avatar
/// - Call duration timer
/// - Audio/video controls (mute, speaker, video toggle)
/// - Live diagnostics panel (jitter, packet loss, RTT, bitrate, quality)
/// - Speaker detection indicator
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.callId,
    required this.recipientName,
    this.isVideo = false,
  });

  final String callId;
  final String recipientName;
  final bool isVideo;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _webrtc = WebRTCService.instance;
  final _ringtone = CallRingtoneService.instance;
  Timer? _durationTimer;
  int _durationSeconds = 0;
  bool _showDiagnostics = false;
  CallDiagnostics? _diagnostics;
  SpeakerInfo? _speakerInfo;
  CallState? _callState;

  @override
  void initState() {
    super.initState();
    _startDuration();
    _listenToDiagnostics();
    _startRingtone();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _ringtone.stop();
    super.dispose();
  }

  void _startRingtone() {
    // Play outgoing ringtone (caller perspective).
    _ringtone.playOutgoing();

    // Stop ringtone when call connects.
    _webrtc.callState.listen((state) {
      if (state.status == CallStatus.connected) {
        _ringtone.stop();
      }
    });
  }

  void _startDuration() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _durationSeconds++);
    });
  }

  void _listenToDiagnostics() {
    _webrtc.diagnostics.listen((d) {
      if (mounted) setState(() => _diagnostics = d);
    });
    _webrtc.speakerInfo.listen((s) {
      if (mounted) setState(() => _speakerInfo = s);
    });
    _webrtc.callState.listen((s) {
      if (mounted) setState(() => _callState = s);
      if (s.status == CallStatus.ended && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    });
  }

  String get _formattedDuration {
    final h = _durationSeconds ~/ 3600;
    final m = (_durationSeconds % 3600) ~/ 60;
    final s = _durationSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top: User info + duration
            _buildHeader(),

            // Middle: Diagnostics or empty space
            Expanded(
              child: _showDiagnostics
                  ? _buildDiagnosticsPanel()
                  : _buildCallView(),
            ),

            // Bottom: Controls
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Avatar
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.1),
              border: Border.all(
                color: _callState?.status == CallStatus.connected
                    ? AthurColors.success
                    : AthurColors.gold.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: Icon(
              widget.isVideo ? Icons.videocam : Icons.person,
              size: 48,
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 16),

          // Name
          Text(
            widget.recipientName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),

          // Duration / Status
          Text(
            _callState?.status == CallStatus.connected
                ? _formattedDuration
                : _callState?.status == CallStatus.calling
                    ? 'Calling...'
                    : 'Connecting...',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 14,
            ),
          ),

          // Speaker indicator
          if (_speakerInfo?.isSpeaking == true) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.mic,
                  size: 16,
                  color: AthurColors.success,
                ),
                const SizedBox(width: 4),
                Text(
                  'Speaking',
                  style: TextStyle(
                    color: AthurColors.success,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCallView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Audio waveform visualization (placeholder)
          Icon(
            Icons.graphic_eq,
            size: 64,
            color: AthurColors.gold.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),

          // Quality indicator
          if (_diagnostics != null) ...[
            _QualityBadge(quality: _diagnostics!.quality),
          ],
        ],
      ),
    );
  }

  Widget _buildDiagnosticsPanel() {
    if (_diagnostics == null) {
      return const Center(
        child: CircularProgressIndicator(color: AthurColors.gold),
      );
    }

    final d = _diagnostics!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quality header
          _DiagnosticsHeader(quality: d.quality),
          const SizedBox(height: 16),

          // Metrics grid
          _MetricsGrid(diagnostics: d),
          const SizedBox(height: 16),

          // Speaker info
          if (_speakerInfo != null) _SpeakerPanel(info: _speakerInfo!),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 16,
        left: 24,
        right: 24,
      ),
      child: Column(
        children: [
          // Diagnostics toggle
          TextButton.icon(
            onPressed: () => setState(() => _showDiagnostics = !_showDiagnostics),
            icon: Icon(
              _showDiagnostics ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: Colors.white54,
            ),
            label: Text(
              _showDiagnostics ? 'Hide Diagnostics' : 'Show Diagnostics',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),

          // Control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Mute
              _ControlButton(
                icon: _webrtc.isMuted ? Icons.mic_off : Icons.mic,
                label: _webrtc.isMuted ? 'Unmute' : 'Mute',
                isActive: _webrtc.isMuted,
                onTap: () => _webrtc.toggleMute(),
              ),

              // Speaker
              _ControlButton(
                icon: _webrtc.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                label: _webrtc.isSpeakerOn ? 'Speaker On' : 'Speaker Off',
                isActive: _webrtc.isSpeakerOn,
                onTap: () => _webrtc.toggleSpeaker(),
              ),

              // End call
              GestureDetector(
                onTap: () async {
                  await _webrtc.endCall();
                  if (mounted) Navigator.of(context).pop();
                },
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    color: AthurColors.danger,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.call_end,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Quality badge.
class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.quality});

  final CallQuality quality;

  @override
  Widget build(BuildContext context) {
    final color = switch (quality) {
      CallQuality.excellent => AthurColors.success,
      CallQuality.good => AthurColors.qualityGood,
      CallQuality.fair => AthurColors.warning,
      CallQuality.poor => AthurColors.qualityPoor,
      CallQuality.critical => AthurColors.danger,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        quality.name.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Diagnostics header.
class _DiagnosticsHeader extends StatelessWidget {
  const _DiagnosticsHeader({required this.quality});

  final CallQuality quality;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Call Diagnostics',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        _QualityBadge(quality: quality),
      ],
    );
  }
}

/// Metrics grid.
class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.diagnostics});

  final CallDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.5,
      children: [
        _MetricCard(
          label: 'Bitrate',
          value: diagnostics.formattedBitrate,
          icon: Icons.speed,
        ),
        _MetricCard(
          label: 'Packet Loss',
          value: '${diagnostics.lossPercentage.toStringAsFixed(1)}%',
          icon: Icons.warning_amber,
          isWarning: diagnostics.lossPercentage > 2,
        ),
        _MetricCard(
          label: 'Jitter',
          value: '${diagnostics.jitter.toStringAsFixed(1)} ms',
          icon: Icons.graphic_eq,
          isWarning: diagnostics.jitter > 30,
        ),
        _MetricCard(
          label: 'RTT',
          value: '${diagnostics.roundTripTimeMs} ms',
          icon: Icons.timer,
          isWarning: diagnostics.roundTripTimeMs > 150,
        ),
        _MetricCard(
          label: 'Codec',
          value: diagnostics.codec.toUpperCase(),
          icon: Icons.audiotrack,
        ),
        _MetricCard(
          label: 'Audio Level',
          value: diagnostics.audioLevel.toString(),
          icon: Icons.mic,
        ),
      ],
    );
  }
}

/// Single metric card.
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.isWarning = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isWarning
              ? AthurColors.warning.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 14,
                color: isWarning ? AthurColors.warning : Colors.white54,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: isWarning ? AthurColors.warning : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Speaker detection panel.
class _SpeakerPanel extends StatelessWidget {
  const _SpeakerPanel({required this.info});

  final SpeakerInfo info;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Speaker Detection',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                info.isSpeaking ? Icons.mic : Icons.mic_off,
                color: info.isSpeaking ? AthurColors.success : Colors.white38,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                info.isSpeaking ? 'Voice detected' : 'Silent',
                style: TextStyle(
                  color: info.isSpeaking ? AthurColors.success : Colors.white54,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                'Level: ${info.audioLevel}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Control button.
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isActive
                  ? AthurColors.gold.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                color: isActive ? AthurColors.gold : Colors.white.withValues(alpha: 0.2),
              ),
            ),
            child: Icon(
              icon,
              color: isActive ? AthurColors.gold : Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
