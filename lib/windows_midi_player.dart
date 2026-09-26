import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// MIDI transport backed by the Windows system MIDI sequencer.
///
/// Android uses Android's native MediaPlayer MIDI decoder through AudioPlayer.
class WindowsMidiPlayer {
  static const _channel = MethodChannel('neonamp/midi');

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();
  final _completeController = StreamController<void>.broadcast();

  Timer? _pollTimer;
  Duration _duration = Duration.zero;
  PlayerState _state = PlayerState.stopped;
  bool _pollInProgress = false;
  bool _completionSent = false;
  bool _disposed = false;
  int _generation = 0;

  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;
  Stream<void> get onPlayerComplete => _completeController.stream;

  Future<void> play(String path, {required double playbackSpeed}) async {
    if (_disposed) throw StateError('The MIDI player has been disposed.');
    final generation = ++_generation;
    _pollTimer?.cancel();
    final safeSpeed = playbackSpeed.isFinite
        ? playbackSpeed.clamp(0.5, 2.0)
        : 1.0;
    final opened = await _channel.invokeMapMethod<String, Object?>(
      'openAndPlay',
      {'path': path, 'speed': safeSpeed},
    );
    if (_disposed || generation != _generation) return;
    if (opened == null) throw StateError('Could not open this MIDI file.');
    _duration = Duration(
      milliseconds: (opened['durationMs'] as num?)?.toInt() ?? 0,
    );
    _completionSent = false;
    _durationController.add(_duration);
    _setState(PlayerState.playing);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      unawaited(_poll(generation));
    });
  }

  Future<void> _poll(int generation) async {
    if (_disposed || generation != _generation) return;
    if (_pollInProgress) return;
    _pollInProgress = true;
    try {
      final snapshot = await _channel.invokeMapMethod<String, Object?>(
        'getState',
      );
      if (_disposed || generation != _generation) return;
      if (snapshot == null) return;
      final position = Duration(
        milliseconds: (snapshot['positionMs'] as num?)?.toInt() ?? 0,
      );
      final mode = snapshot['mode'];
      if (mode == 'playing') {
        _positionController.add(position);
        if (_state != PlayerState.playing) _setState(PlayerState.playing);
      } else if (_state == PlayerState.playing) {
        if (_duration > Duration.zero &&
            position >= _duration - const Duration(milliseconds: 350) &&
            !_completionSent) {
          _positionController.add(_duration);
          _setState(PlayerState.completed);
          _completionSent = true;
          _completeController.add(null);
        } else {
          _setState(PlayerState.stopped);
        }
        _pollTimer?.cancel();
      }
    } on Object {
      if (_disposed || generation != _generation) return;
      _pollTimer?.cancel();
      _setState(PlayerState.stopped);
    } finally {
      _pollInProgress = false;
    }
  }

  Future<void> pause() async {
    if (_disposed) return;
    final generation = _generation;
    await _channel.invokeMethod<void>('pause');
    if (_disposed || generation != _generation) return;
    _setState(PlayerState.paused);
  }

  Future<void> resume() async {
    if (_disposed) return;
    final generation = _generation;
    await _channel.invokeMethod<void>('resume');
    if (_disposed || generation != _generation) return;
    _setState(PlayerState.playing);
  }

  Future<void> stop() async {
    if (_disposed) return;
    final generation = ++_generation;
    _pollTimer?.cancel();
    try {
      await _channel.invokeMethod<void>('stop');
    } on Object {
      // Native playback may already be stopped during activity teardown.
    }
    if (_disposed || generation != _generation) return;
    _setState(PlayerState.stopped);
    _positionController.add(Duration.zero);
  }

  Future<void> seek(Duration position) async {
    if (_disposed) return;
    final generation = _generation;
    final clamped = position < Duration.zero
        ? Duration.zero
        : position > _duration
        ? _duration
        : position;
    await _channel.invokeMethod<void>('seek', {
      'positionMs': clamped.inMilliseconds,
    });
    if (_disposed || generation != _generation) return;
    _positionController.add(clamped);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (_disposed) return;
    final generation = _generation;
    await _channel.invokeMethod<void>('setPlaybackSpeed', {
      'speed': speed.isFinite ? speed.clamp(0.5, 2.0) : 1.0,
    });
    if (_disposed || generation != _generation) return;
  }

  void _setState(PlayerState state) {
    _state = state;
    _stateController.add(state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _pollTimer?.cancel();
    try {
      await _channel.invokeMethod<void>('close');
    } on Object {
      // The app can be shutting down while the runner is already closing.
    }
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _completeController.close();
  }
}
