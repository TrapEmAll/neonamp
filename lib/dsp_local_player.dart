import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_soloud/flutter_soloud.dart' as soloud;

import 'tracker_modules.dart';

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
  String? _renderedModulePath;
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
    if (_disposed) throw StateError('The DSP player has been disposed.');
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
    double balance = 0,
  }) async {
    await _ensureInitialized();
    await stop();
    final isTrackerModule = isTrackerModulePath(path);
    var sourcePath = path;
    if (isTrackerModule) {
      sourcePath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'neonamp-tracker-${DateTime.now().microsecondsSinceEpoch}.wav';
      try {
        await TrackerModuleDecoder.decodeToWav(path, sourcePath);
      } on Object {
        final output = File(sourcePath);
        if (await output.exists()) await output.delete();
        rethrow;
      }
    }
    late final soloud.AudioSource source;
    try {
      source = await soloud.SoLoud.instance.loadFile(
        sourcePath,
        mode: isTrackerModule ? soloud.LoadMode.disk : soloud.LoadMode.memory,
      );
    } on Object {
      if (isTrackerModule) {
        final output = File(sourcePath);
        if (await output.exists()) await output.delete();
      }
      rethrow;
    }
    final equalizer = source.filters.parametricEqFilter;
    equalizer.activate();
    equalizer.numBands().value = bands.length.toDouble();
    for (var index = 0; index < bands.length; index++) {
      final gain = equalizerEnabled ? dspGainForDb(bands[index]) : 1.0;
      equalizer.bandGain(index).value = gain;
    }
    final handle = soloud.SoLoud.instance.play(
      source,
      volume: volume,
      pan: balance.clamp(-1.0, 1.0),
    );
    soloud.SoLoud.instance.setRelativePlaySpeed(handle, playbackSpeed);
    _source = source;
    _renderedModulePath = isTrackerModule ? sourcePath : null;
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
    final duration = _source == null
        ? Duration.zero
        : soloud.SoLoud.instance.getLength(_source!);
    final target = position.isNegative
        ? Duration.zero
        : duration > Duration.zero && position > duration
        ? duration
        : position;
    soloud.SoLoud.instance.seek(handle, target);
    _positionController.add(target);
  }

  Future<void> setVolume(double volume) async {
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setVolume(handle, volume);
    }
  }

  void setBalance(double balance) {
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.isInitialized &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setPan(handle, balance.clamp(-1.0, 1.0));
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setRelativePlaySpeed(
        handle,
        speed.clamp(0.5, 2.0).toDouble(),
      );
    }
  }

  void setVisualizationEnabled(bool enabled) {
    if (!soloud.SoLoud.instance.isInitialized) return;
    soloud.SoLoud.instance.setVisualizationEnabled(
      enabled,
      windowSize: 512,
      kind: soloud.VisualizationKind.waveAndFft,
    );
  }

  void applyEqualizer({required bool enabled, required List<double> bands}) {
    final source = _source;
    if (source == null) return;
    final equalizer = source.filters.parametricEqFilter;
    equalizer.activate();
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
    final renderedModulePath = _renderedModulePath;
    _renderedModulePath = null;
    if (renderedModulePath != null) {
      final renderedModule = File(renderedModulePath);
      if (await renderedModule.exists()) await renderedModule.delete();
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
