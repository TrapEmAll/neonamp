import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter_soloud/flutter_soloud.dart' as soloud;

import 'tracker_modules.dart';
import 'audio_effects.dart';
import 'audio_loudness.dart';

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
  String? _temporaryAudioPath;
  Timer? _pollTimer;
  bool _completionSent = false;
  bool _disposed = false;
  Duration _duration = Duration.zero;
  double _volume = 1;
  double _preamp = 0;

  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<PlayerState> get onPlayerStateChanged => _stateController.stream;
  Stream<void> get onPlayerComplete => _completeController.stream;
  Duration get duration => _duration;
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
    List<double> frequencies = const [],
    double preamp = 0,
    bool truePeakLimiterEnabled = true,
    List<PortableAudioEffect> effects = const [],
    double balance = 0,
    bool deleteSourceOnStop = false,
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
    String? transcodedAudioPath;
    late final soloud.AudioSource source;
    try {
      try {
        source = await soloud.SoLoud.instance.loadFile(
          sourcePath,
          mode: isTrackerModule || deleteSourceOnStop
              ? soloud.LoadMode.disk
              : soloud.LoadMode.memory,
        );
      } on Object {
        if (isTrackerModule || deleteSourceOnStop) rethrow;
        transcodedAudioPath = await _transcodeToWav(path);
        source = await soloud.SoLoud.instance.loadFile(
          transcodedAudioPath,
          mode: soloud.LoadMode.disk,
        );
        sourcePath = transcodedAudioPath;
      }
    } on Object {
      if (isTrackerModule || transcodedAudioPath != null) {
        final output = File(transcodedAudioPath ?? sourcePath);
        if (await output.exists()) await output.delete();
      }
      rethrow;
    }
    final equalizer = source.filters.parametricEqFilter..activate();
    final limiter = source.filters.limiterFilter;
    _volume = volume.clamp(0.0, 1.0).toDouble();
    _preamp = preamp.clamp(-12.0, 12.0).toDouble();
    final handle = soloud.SoLoud.instance.play(
      source,
      volume: _effectiveVolume,
      pan: balance.clamp(-1.0, 1.0),
    );
    if (truePeakLimiterEnabled) {
      limiter.activate();
      limiter.wet(soundHandle: handle).value = 1.0;
      limiter.threshold(soundHandle: handle).value = -3.0;
      limiter.outputCeiling(soundHandle: handle).value = defaultTruePeakCeilingDb;
      limiter.attackTime(soundHandle: handle).value = 1.0;
      limiter.releaseTime(soundHandle: handle).value = 100.0;
      limiter.kneeWidth(soundHandle: handle).value = 2.0;
    }
    equalizer.numBands(soundHandle: handle).value = bands.length.toDouble();
    for (var index = 0; index < bands.length; index++) {
      final gain = equalizerEnabled ? dspGainForDb(bands[index]) : 1.0;
      equalizer.bandGain(index, soundHandle: handle).value = gain;
    }
    _applyPortableEffects(source, handle, effects);
    soloud.SoLoud.instance.setRelativePlaySpeed(handle, playbackSpeed);
    _source = source;
    _temporaryAudioPath = isTrackerModule || transcodedAudioPath != null
        ? sourcePath
        : deleteSourceOnStop
        ? sourcePath
        : null;
    _handle = handle;
    _completionSent = false;
    _duration = soloud.SoLoud.instance.getLength(source);
    _durationController.add(_duration);
    _stateController.add(PlayerState.playing);
    _startPolling();
  }

  Future<String> _transcodeToWav(String inputPath) async {
    final outputPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'neonamp-decoded-${DateTime.now().microsecondsSinceEpoch}.wav';
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-nostdin',
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        inputPath,
        '-map',
        '0:a:0',
        '-vn',
        '-c:a',
        'pcm_s16le',
        '-ar',
        '44100',
        '-ac',
        '2',
        '-f',
        'wav',
        outputPath,
      ]);
      final returnCode = await session.getReturnCode();
      final output = File(outputPath);
      if (!ReturnCode.isSuccess(returnCode) ||
          !await output.exists() ||
          await output.length() <= 44) {
        final outputText = (await session.getOutput())?.trim();
        final logs = outputText == null
            ? null
            : outputText.length > 500
            ? outputText.substring(outputText.length - 500)
            : outputText;
        throw StateError(
          'Could not decode this audio file with the bundled fallback decoder'
          '${logs == null || logs.isEmpty ? '.' : ': $logs'}',
        );
      }
      return outputPath;
    } on Object {
      final output = File(outputPath);
      if (await output.exists()) await output.delete();
      rethrow;
    }
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

  double get _effectiveVolume =>
      (_volume * dspGainForDb(_preamp)).clamp(0.0, 1.0).toDouble();

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0).toDouble();
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setVolume(handle, _effectiveVolume);
    }
  }

  void setPreamp(double preamp) {
    _preamp = preamp.clamp(-12.0, 12.0).toDouble();
    final handle = _handle;
    if (handle != null &&
        soloud.SoLoud.instance.isInitialized &&
        soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      soloud.SoLoud.instance.setVolume(handle, _effectiveVolume);
    }
  }

  void setTruePeakLimiter(bool enabled) {
    final source = _source;
    final handle = _handle;
    if (source == null ||
        handle == null ||
        !soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      return;
    }
    final limiter = source.filters.limiterFilter;
    if (!enabled) {
      limiter.deactivate();
      return;
    }
    limiter
      ..activate()
      ..wet(soundHandle: handle).value = 1.0
      ..threshold(soundHandle: handle).value = -3.0
      ..outputCeiling(soundHandle: handle).value = defaultTruePeakCeilingDb
      ..attackTime(soundHandle: handle).value = 1.0
      ..releaseTime(soundHandle: handle).value = 100.0
      ..kneeWidth(soundHandle: handle).value = 2.0;
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
      soloud.SoLoud.instance.setRelativePlaySpeed(handle, speed);
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

  void applyEqualizer({
    required bool enabled,
    required List<double> bands,
    List<double> frequencies = const [],
  }) {
    final source = _source;
    final handle = _handle;
    if (source == null ||
        handle == null ||
        !soloud.SoLoud.instance.getIsValidVoiceHandle(handle)) {
      return;
    }
    final equalizer = source.filters.parametricEqFilter;
    equalizer.activate();
    equalizer.numBands(soundHandle: handle).value = bands.length.toDouble();
    for (var index = 0; index < bands.length; index++) {
      final gain = enabled ? dspGainForDb(bands[index]) : 1.0;
      equalizer.bandGain(index, soundHandle: handle).value = gain;
    }
  }

  void _applyPortableEffects(
    soloud.AudioSource source,
    soloud.SoundHandle handle,
    List<PortableAudioEffect> effects,
  ) {
    for (final effect in effects) {
      switch (effect.type) {
        case 'bassBoost':
          final filter = source.filters.bassBoostFilter..activate();
          filter.wet(soundHandle: handle).value = effect.value('wet');
          filter.boost(soundHandle: handle).value = effect.value('boost');
        case 'echo':
          final filter = source.filters.echoFilter..activate();
          filter.wet(soundHandle: handle).value = effect.value('wet');
          filter.delay(soundHandle: handle).value = effect.value('delay');
          filter.decay(soundHandle: handle).value = effect.value('decay');
          filter.filter(soundHandle: handle).value = effect.value('filter');
        case 'reverb':
          final filter = source.filters.freeverbFilter..activate();
          filter.wet(soundHandle: handle).value = effect.value('wet');
          filter.freeze(soundHandle: handle).value = effect.value('freeze');
          filter.roomSize(soundHandle: handle).value = effect.value('roomSize');
          filter.damp(soundHandle: handle).value = effect.value('damp');
          filter.width(soundHandle: handle).value = effect.value('width');
      }
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
    final temporaryAudioPath = _temporaryAudioPath;
    _temporaryAudioPath = null;
    if (temporaryAudioPath != null) {
      final temporaryAudio = File(temporaryAudioPath);
      if (await temporaryAudio.exists()) await temporaryAudio.delete();
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

