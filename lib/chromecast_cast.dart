import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/services.dart';

/// Audio-only Chromecast transport. DLNA remains handled by [DlnaCast].
class ChromecastCast {
  static const MethodChannel _androidChannel = MethodChannel('neonamp/dlna');
  late final CastService _service = CastService(
    discoveryProviders: [ChromecastDiscoveryProvider()],
    sessionFactory: (device) => ChromecastSession(device: device),
  );
  CastSession? _session;
  Duration _segmentStart = Duration.zero;
  Duration? _segmentDuration;

  bool get isConnected => _session != null;
  String? get deviceName => _session?.device.name;

  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (Platform.isAndroid &&
        await _androidChannel.invokeMethod<bool>('beginDiscovery') != true) {
      throw StateError('Nearby devices permission was not granted.');
    }
    try {
      var devices = <CastDevice>[];
      await for (final found in _service.startDiscovery(
        protocols: {CastProtocol.chromecast},
        timeout: timeout,
      )) {
        devices = found;
      }
      return devices;
    } finally {
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<void>('endDiscovery');
      }
    }
  }

  Future<void> play({
    required CastDevice device,
    required String path,
    required String title,
    required Duration duration,
    Duration segmentStart = Duration.zero,
    Duration startPosition = Duration.zero,
  }) async {
    final contentType = audioContentType(path);
    if (contentType == null) {
      throw UnsupportedError(
        'This audio format is not supported by Chromecast.',
      );
    }
    final session = await _service.connect(device);
    _session = session;
    try {
      final media = CastMedia(
        url: path,
        type: CastMediaType.mp4,
        contentType: contentType,
        metadataType: 3,
        title: title,
        duration: segmentStart + duration,
        startPosition: segmentStart + startPosition,
      );
      final castMedia =
          path.startsWith('http://') || path.startsWith('https://')
          ? media
          : CastMedia.file(
              filePath: path,
              type: CastMediaType.mp4,
              contentType: contentType,
              metadataType: 3,
              title: title,
              duration: segmentStart + duration,
              startPosition: segmentStart + startPosition,
            );
      await session.loadMedia(castMedia);
      _segmentStart = segmentStart;
      _segmentDuration = duration;
    } catch (_) {
      _session = null;
      await session.disconnect();
      rethrow;
    }
  }

  Future<void> pause() async => _session?.pause();
  Future<void> resume() async => _session?.play();
  Future<void> seek(Duration position) async =>
      _session?.seek(_toSourcePosition(position));
  Future<void> setVolume(double value) async => _session?.setVolume(value);
  Future<Duration?> getPosition() async {
    final session = _session;
    if (session == null) return null;
    var relative = session.position - _segmentStart;
    if (relative.isNegative) relative = Duration.zero;
    final limit = _segmentDuration;
    if (limit != null && relative > limit) relative = limit;
    return relative;
  }

  Duration _toSourcePosition(Duration position) {
    var relative = position.isNegative ? Duration.zero : position;
    final limit = _segmentDuration;
    if (limit != null && relative > limit) relative = limit;
    return _segmentStart + relative;
  }

  Future<void> stop() async {
    final session = _session;
    _session = null;
    _segmentStart = Duration.zero;
    _segmentDuration = null;
    if (session == null) return;
    try {
      await session.stop();
    } finally {
      await session.disconnect();
    }
  }

  Future<void> dispose() async {
    _session = null;
    await _service.dispose();
  }
}

String? audioContentType(String path) {
  final extension = path.split('?').first.split('.').last.toLowerCase();
  return const {
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'wav': 'audio/wav',
    'wave': 'audio/wav',
    'ogg': 'audio/ogg',
    'oga': 'audio/ogg',
    'opus': 'audio/ogg',
    'flac': 'audio/flac',
  }[extension];
}
