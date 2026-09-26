import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_soloud/flutter_soloud.dart' as soloud;

import 'tracker_modules.dart';

double dspGainForDb(double decibels) {
  if (!decibels.isFinite) return 1.0;
  return math.pow(10, decibels / 20).toDouble().clamp(0.0, 4.0);
}

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
  Future<void>? _initialization;
  bool _completionSent = false;
  bool _disposed = false;
  int _generation = 0;

  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;
  Stream<void> get onPlayerComplete => _completeController.stream;
  PlayerState get state {
    final handle = _validHandle(_handle);
    if (handle == null) return PlayerState.stopped;
    return soloud.SoLoud.instance.getPause(handle)
        ? PlayerState.paused
        : PlayerState.playing;
  }

  Future<void> _ensureInitialized() async {
    if (_disposed) throw StateError('The DSP player has been disposed.');
    if (soloud.SoLoud.instance.isInitialized) return;
    _initialization ??= soloud.SoLoud.instance.init();
    try {
      await _initialization;
    } finally {
      _initialization = null;
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
    if (_disposed) throw StateError('The DSP player has been disposed.');
    final generation = ++_generation;
    await _ensureInitialized();
    if (_disposed || generation != _generation) return;
    await stop(invalidate: false, expectedGeneration: generation);
    if (_disposed || generation != _generation) return;
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
      if (_disposed || generation != _generation) {
        final output = File(sourcePath);
        if (await output.exists()) await output.delete();
        return;
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
    if (_disposed || generation != _generation) {
      await _disposeSourceSafely(source);
      if (isTrackerModule) await _deleteRenderedModule(sourcePath);
      return;
    }
    soloud.SoundHandle? handle;
    try {
      final equalizer = source.filters.parametricEqFilter;
      equalizer.activate();
      equalizer.numBands().value = bands.length.toDouble();
      for (var index = 0; index < bands.length; index++) {
        final gain = equalizerEnabled ? dspGainForDb(bands[index]) : 1.0;
        equalizer.bandGain(index).value = gain;
      }
      handle = soloud.SoLoud.instance.play(
        source,
        volume: volume.clamp(0.0, 1.0).toDouble(),
        pan: balance.clamp(-1.0, 1.0),
      );
      soloud.SoLoud.instance.setRelativePlaySpeed(
        handle,
        playbackSpeed.isFinite ? playbackSpeed.clamp(0.5, 2.0).toDouble() : 1,
      );
      _source = source;
      _renderedModulePath = isTrackerModule ? sourcePath : null;
      _handle = handle;
      _completionSent = false;
      _durationController.add(soloud.SoLoud.instance.getLength(source));
      _stateController.add(PlayerState.playing);
      _startPolling();
    } on Object {
      // If playback started before a later setup step failed, stop that voice
      // before releasing its source.
      if (handle != null &&
          soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
        try {
          await soloud.SoLoud.instance.stop(handle);
        } on Object {
          // Continue releasing the source and temporary file.
        }
      }
      await _disposeSourceSafely(source);
      if (isTrackerModule) {
        final output = File(sourcePath);
        if (await output.exists()) await output.delete();
      }
      rethrow;
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_disposed || !soloud.SoLoud.instance.isInitialized) return;
      final handle = _handle;
      if (handle == null) return;
      if (!soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
        _pollTimer?.cancel();
        _handle = null;
        final source = _source;
        _source = null;
        final renderedModulePath = _renderedModulePath;
        _renderedModulePath = null;
        if (source != null) {
          unawaited(_disposeSourceSafely(source));
        }
        if (renderedModulePath != null) {
          unawaited(_deleteRenderedModule(renderedModulePath));
        }
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

  Future<void> _deleteRenderedModule(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // Temporary tracker output is best-effort cleanup.
    }
  }

  Future<void> _disposeSourceSafely(soloud.AudioSource source) async {
    try {
      await soloud.SoLoud.instance.disposeSource(source);
    } on Object {
      // SoLoud may already have released a source after voice completion.
    }
  }

  Future<void> pause() async {
    if (_disposed) return;
    final handle = _validHandle(_handle);
    if (handle == null) return;
    soloud.SoLoud.instance.setPause(handle, true);
    _stateController.add(PlayerState.paused);
  }

  Future<void> resume() async {
    if (_disposed) return;
    final handle = _validHandle(_handle);
    if (handle == null) return;
    soloud.SoLoud.instance.setPause(handle, false);
    _stateController.add(PlayerState.playing);
  }

  Future<void> seek(Duration position) async {
    if (_disposed) return;
    final handle = _validHandle(_handle);
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
    if (_disposed) return;
    final handle = _validHandle(_handle);
    if (handle != null) {
      final safeVolume = volume.isFinite ? volume.clamp(0.0, 1.0) : 0.0;
      soloud.SoLoud.instance.setVolume(handle, safeVolume);
    }
  }

  void setBalance(double balance) {
    if (_disposed) return;
    final handle = _validHandle(_handle);
    if (handle != null) {
      soloud.SoLoud.instance.setPan(handle, balance.clamp(-1.0, 1.0));
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (_disposed) return;
    final handle = _validHandle(_handle);
    if (handle != null) {
      soloud.SoLoud.instance.setRelativePlaySpeed(
        handle,
        (speed.isFinite ? speed.clamp(0.5, 2.0) : 1.0).toDouble(),
      );
    }
  }

  void setVisualizationEnabled(bool enabled) {
    if (_disposed || !soloud.SoLoud.instance.isInitialized) return;
    soloud.SoLoud.instance.setVisualizationEnabled(
      enabled,
      windowSize: 512,
      kind: soloud.VisualizationKind.waveAndFft,
    );
  }

  void applyEqualizer({required bool enabled, required List<double> bands}) {
    if (_disposed) return;
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

  Future<void> stop({bool invalidate = true, int? expectedGeneration}) async {
    if (expectedGeneration != null && expectedGeneration != _generation) {
      return;
    }
    final generation = invalidate ? ++_generation : _generation;
    _pollTimer?.cancel();
    final handle = _handle;
    try {
      final validHandle = _validHandle(handle);
      if (validHandle != null) {
        await soloud.SoLoud.instance.stop(validHandle);
      }
    } finally {
      if (generation == _generation) {
        _handle = null;
        final source = _source;
        _source = null;
        if (source != null && soloud.SoLoud.instance.isInitialized) {
          await _disposeSourceSafely(source);
        }
        final renderedModulePath = _renderedModulePath;
        _renderedModulePath = null;
        if (renderedModulePath != null) {
          await _deleteRenderedModule(renderedModulePath);
        }
      }
    }
    if (!_disposed && generation == _generation) {
      _stateController.add(PlayerState.stopped);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await stop();
    await _positionController.close();
    await _durationController.close();
    await _stateController.close();
    await _completeController.close();
  }

  soloud.SoundHandle? _validHandle(soloud.SoundHandle? handle) {
    if (handle == null || !soloud.SoLoud.instance.isInitialized) return null;
    return soloud.SoLoud.instance.getIsValidVoiceHandle(handle) ? handle : null;
  }
}
