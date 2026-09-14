import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Handles voice recording for voice messages.
///
/// Usage:
/// ```dart
/// final recorder = VoiceRecordingService.instance;
/// await recorder.startRecording();
/// // ... user records ...
/// final file = await recorder.stopRecording();
/// ```
class VoiceRecordingService {
  VoiceRecordingService._();

  static final VoiceRecordingService instance = VoiceRecordingService._();

  final _audioRecorder = AudioRecorder();
  final _recordingController = StreamController<RecordingState>.broadcast();

  RecordingState _currentState = RecordingState.idle;
  Timer? _durationTimer;
  int _durationSeconds = 0;
  String? _currentFilePath;

  /// Current recording state.
  Stream<RecordingState> get state => _recordingController.stream;

  /// Current recording duration in seconds.
  int get durationSeconds => _durationSeconds;

  /// Whether currently recording.
  bool get isRecording => _currentState == RecordingState.recording;

  // ────────────────────────── Lifecycle ──────────────────────────

  /// Initializes the recorder and checks permissions.
  Future<bool> init() async {
    if (!await _audioRecorder.hasPermission()) {
      debugPrint('[Athur][recorder] No microphone permission');
      return false;
    }
    return true;
  }

  /// Starts recording audio.
  Future<bool> startRecording() async {
    if (_currentState == RecordingState.recording) return false;

    // Check permission.
    if (!await _audioRecorder.hasPermission()) {
      _updateState(RecordingState.error);
      return false;
    }

    // Get temporary directory for recording.
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _currentFilePath = '${tempDir.path}/voice_$timestamp.m4a';

    try {
      await _audioRecorder.start(
        RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
          numChannels: 1,
          // Noise suppression and echo cancellation for clean voice.
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: _currentFilePath!,
      );

      _durationSeconds = 0;
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _durationSeconds++;
      });

      _updateState(RecordingState.recording);
      debugPrint('[Athur][recorder] Started: $_currentFilePath');
      return true;
    } catch (e) {
      debugPrint('[Athur][recorder] Failed to start: $e');
      _updateState(RecordingState.error);
      return false;
    }
  }

  /// Pauses the current recording.
  Future<void> pauseRecording() async {
    if (_currentState != RecordingState.recording) return;
    await _audioRecorder.pause();
    _durationTimer?.cancel();
    _updateState(RecordingState.paused);
  }

  /// Resumes a paused recording.
  Future<void> resumeRecording() async {
    if (_currentState != RecordingState.paused) return;
    await _audioRecorder.resume();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _durationSeconds++;
    });
    _updateState(RecordingState.recording);
  }

  /// Stops recording and returns the recorded file.
  Future<VoiceRecordingResult?> stopRecording() async {
    _durationTimer?.cancel();

    if (_currentFilePath == null) {
      _updateState(RecordingState.idle);
      return null;
    }

    try {
      final path = await _audioRecorder.stop();
      final file = File(path ?? _currentFilePath!);

      if (!await file.exists()) {
        debugPrint('[Athur][recorder] File not found after stop');
        _updateState(RecordingState.idle);
        return null;
      }

      final result = VoiceRecordingResult(
        filePath: file.path,
        durationSeconds: _durationSeconds,
        fileSize: await file.length(),
      );

      debugPrint('[Athur][recorder] Stopped: ${result.filePath} (${result.durationSeconds}s, ${result.fileSize} bytes)');

      _currentFilePath = null;
      _durationSeconds = 0;
      _updateState(RecordingState.idle);

      return result;
    } catch (e) {
      debugPrint('[Athur][recorder] Failed to stop: $e');
      _updateState(RecordingState.error);
      return null;
    }
  }

  /// Cancels the current recording and deletes the file.
  Future<void> cancelRecording() async {
    _durationTimer?.cancel();
    await _audioRecorder.stop();

    if (_currentFilePath != null) {
      final file = File(_currentFilePath!);
      if (await file.exists()) {
        await file.delete();
      }
      _currentFilePath = null;
    }

    _durationSeconds = 0;
    _updateState(RecordingState.idle);
  }

  /// Releases resources.
  Future<void> dispose() async {
    _durationTimer?.cancel();
    await _audioRecorder.dispose();
    await _recordingController.close();
  }

  // ────────────────────────── Private ──────────────────────────

  void _updateState(RecordingState state) {
    _currentState = state;
    _recordingController.add(state);
  }
}

/// Recording state.
enum RecordingState { idle, recording, paused, error }

/// Result of a voice recording.
class VoiceRecordingResult {
  const VoiceRecordingResult({
    required this.filePath,
    required this.durationSeconds,
    required this.fileSize,
  });

  final String filePath;
  final int durationSeconds;
  final int fileSize;

  /// Formatted duration string (MM:SS).
  String get formattedDuration {
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
