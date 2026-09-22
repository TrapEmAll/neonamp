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

  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;
  Stream<void> get onPlayerComplete => _completeController.stream;

  Future<void> play(String path, {required double playbackSpeed}) async {
    _pollTimer?.cancel();
    final opened = await _channel.invokeMapMethod<String, Object?>(
      'openAndPlay',
      {'path': path, 'speed': playbackSpeed.clamp(0.5, 2.0)},
    );
    if (opened == null) throw StateError('Could not open this MIDI file.');
    _duration = Duration(
      milliseconds: (opened['durationMs'] as num?)?.toInt() ?? 0,
    );
    _completionSent = false;
    _durationController.add(_duration);
    _setState(PlayerState.playing);
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      unawaited(_poll());
    });
  }

  Future<void> _poll() async {
    if (_pollInProgress) return;
    _pollInProgress = true;
    try {
      final snapshot = await _channel.invokeMapMethod<String, Object?>(
        'getState',
      );
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
    } on PlatformException {
      _pollTimer?.cancel();
      _setState(PlayerState.stopped);
    } finally {
      _pollInProgress = false;
    }
  }

  Future<void> pause() async {
    await _channel.invokeMethod<void>('pause');
    _setState(PlayerState.paused);
  }

  Future<void> resume() async {
    await _channel.invokeMethod<void>('resume');
    _setState(PlayerState.playing);
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    await _channel.invokeMethod<void>('stop');
    _setState(PlayerState.stopped);
    _positionController.add(Duration.zero);
  }

  Future<void> seek(Duration position) async {
    final clamped = position < Duration.zero
        ? Duration.zero
        : position > _duration
        ? _duration
        : position;
    await _channel.invokeMethod<void>('seek', {
      'positionMs': clamped.inMilliseconds,
    });
    _positionController.add(clamped);
  }

  Future<void> setPlaybackSpeed(double speed) => _channel.invokeMethod<void>(
    'setPlaybackSpeed',
    {'speed': speed.clamp(0.5, 2.0)},
  );

  void _setState(PlayerState state) {
    _state = state;
    _stateController.add(state);
  }

  Future<void> dispose() async {
    _pollTimer?.cancel();
    try {
      await _channel.invokeMethod<void>('close');
    } on PlatformException {
      // The app can be shutting down while the runner is already closing.
    }
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _completeController.close();
  }
}
