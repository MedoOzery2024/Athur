import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../constants/athur_assets.dart';

/// Handles call ringtones: playing on outgoing/incoming calls and stopping
/// when the call connects.
///
/// Usage:
/// ```dart
/// final ringtone = CallRingtoneService.instance;
/// await ringtone.playOutgoing();
/// await ringtone.playIncoming();
/// await ringtone.stop();
/// ```
class CallRingtoneService {
  CallRingtoneService._();

  static final CallRingtoneService instance = CallRingtoneService._();

  final _audioPlayer = AudioPlayer();
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;

  // ────────────────────────── Lifecycle ──────────────────────────

  /// Plays the outgoing call ringtone (caller hears this).
  Future<void> playOutgoing() async {
    if (_isPlaying) return;

    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setVolume(0.8);
      await _audioPlayer.setSource(AssetSource(AthurAssets.ringtone));
      await _audioPlayer.resume();
      _isPlaying = true;
      debugPrint('[Athur][ringtone] Playing outgoing ringtone');
    } catch (e) {
      debugPrint('[Athur][ringtone] Failed to play outgoing: $e');
    }
  }

  /// Plays the incoming call ringtone (callee hears this).
  Future<void> playIncoming() async {
    if (_isPlaying) return;

    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setVolume(1.0);
      await _audioPlayer.setSource(AssetSource(AthurAssets.ringtone));
      await _audioPlayer.resume();
      _isPlaying = true;
      debugPrint('[Athur][ringtone] Playing incoming ringtone');
    } catch (e) {
      debugPrint('[Athur][ringtone] Failed to play incoming: $e');
    }
  }

  /// Stops the ringtone (call connected or rejected).
  Future<void> stop() async {
    if (!_isPlaying) return;

    try {
      await _audioPlayer.stop();
      _isPlaying = false;
      debugPrint('[Athur][ringtone] Stopped');
    } catch (e) {
      debugPrint('[Athur][ringtone] Failed to stop: $e');
    }
  }

  /// Releases resources.
  Future<void> dispose() async {
    await _audioPlayer.dispose();
    _isPlaying = false;
  }
}
