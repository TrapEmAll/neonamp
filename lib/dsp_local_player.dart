import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_soloud/flutter_soloud.dart' as soloud;

double dspGainForDb(double decibels) =>
    math.pow(10, decibels / 20).toDouble().clamp(0.0, 4.0);

/// Native local-file playback with a real parametric EQ filter.
///
/// Streams and remote URLs continue to use AudioPlayers because SoLoud's
/// native file decoder is intentionally used only for files available on the
/// device. The owner supplies the same ten slider values used by the UI.
class DspLocalPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _stateController = StreamController<PlayerState>.broadcast();
  final _completeController = StreamController<void>.broadcast();

  soloud.AudioSource? _source;
  soloud.SoundHandle? _handle;
  Timer? _pollTimer;
  bool _completionSent = false;
  bool _disposed = false;

  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;
  Stream<void> get onPlayerComplete => _completeController.stream;
  PlayerState get state {
    final handle = _handle;
    if (handle == null ||
        !soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      return PlayerState.stopped;
    }
    return soloud.SoLoud.instance.getPause(handle)
        ? PlayerState.paused
        : PlayerState.playing;
  }

  Future<void> _ensureInitialized() async {
    if (!soloud.SoLoud.instance.isInitialized) {
      await soloud.SoLoud.instance.init();
    }
  }

  Future<void> play(
    String path, {
    required double volume,
    required double playbackSpeed,
    required bool equalizerEnabled,
    required List<double> bands,
  }) async {
    await _ensureInitialized();
    await stop();
    final source = await soloud.SoLoud.instance.loadFile(
      path,
      mode: soloud.LoadMode.memory,
    );
    final equalizer = source.filters.parametricEqFilter;
    equalizer.activate();
    equalizer.numBands().value = bands.length.toDouble();
    for (var index = 0; index < bands.length; index++) {
      final gain = equalizerEnabled ? dspGainForDb(bands[index]) : 1.0;
      equalizer.bandGain(index).value = gain;
    }
    final handle = soloud.SoLoud.instance.play(source, volume: volume);
    soloud.SoLoud.instance.setRelativePlaySpeed(handle, playbackSpeed);
    _source = source;
    _handle = handle;
    _completionSent = false;
    _durationController.add(soloud.SoLoud.instance.getLength(source));
    _stateController.add(PlayerState.playing);
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final handle = _handle;
      if (handle == null) return;
      if (!soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
        _pollTimer?.cancel();
        _handle = null;
        _stateController.add(PlayerState.completed);
        if (!_completionSent) {
          _completionSent = true;
          _completeController.add(null);
        }
        return;
      }
      _positionController.add(soloud.SoLoud.instance.getPosition(handle));
      _stateController.add(state);
    });
  }

  Future<void> pause() async {
    final handle = _handle;
    if (handle == null) return;
    soloud.SoLoud.instance.setPause(handle, true);
    _stateController.add(PlayerState.paused);
  }

  Future<void> resume() async {
    final handle = _handle;
    if (handle == null) return;
    soloud.SoLoud.instance.setPause(handle, false);
    _stateController.add(PlayerState.playing);
  }

  Future<void> seek(Duration position) async {
    final handle = _handle;
    if (handle == null) return;
    soloud.SoLoud.instance.seek(handle, position);
    _positionController.add(position);
  }

  Future<void> setVolume(double volume) async {
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setVolume(handle, volume);
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setRelativePlaySpeed(handle, speed);
    }
  }

  void applyEqualizer({required bool enabled, required List<double> bands}) {
    final source = _source;
    if (source == null) return;
    final equalizer = source.filters.parametricEqFilter;
    equalizer.numBands().value = bands.length.toDouble();
    for (var index = 0; index < bands.length; index++) {
      final gain = enabled ? dspGainForDb(bands[index]) : 1.0;
      equalizer.bandGain(index).value = gain;
    }
  }

  Future<void> stop() async {
    _pollTimer?.cancel();
    final handle = _handle;
    if (handle != null && soloud.SoLoud.instance.isInitialized) {
      await soloud.SoLoud.instance.stop(handle);
    }
    _handle = null;
    final source = _source;
    _source = null;
    if (source != null && soloud.SoLoud.instance.isInitialized) {
      await soloud.SoLoud.instance.disposeSource(source);
    }
    if (!_disposed) _stateController.add(PlayerState.stopped);
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _completeController.close();
  }
}
