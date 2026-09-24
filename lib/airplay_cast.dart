import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/services.dart';

/// AirPlay transport shared by Windows and Android.
///
/// The bundled dart_cast implementation handles AirPlay discovery, HTTP
/// proxying for local files, playback controls, and AirPlay 2 pairing when a
/// receiver requires it. NeonAmp intentionally keeps this behind the same
/// small transport surface used by Chromecast and DLNA.
class AirPlayCast {
  static const MethodChannel _androidChannel = MethodChannel('neonamp/dlna');
  late final CastService _service = CastService(
    discoveryProviders: [AirPlayDiscoveryProvider()],
    sessionFactory: (device) => AirPlaySession(
      device,
      credentials: _credentials[device.id],
    ),
  );
  CastSession? _session;
  final Map<String, HapCredentials> _credentials = {};

  bool get isConnected => _session != null;
  String? get deviceName => _session?.device.name;
  CastDevice? get device => _session?.device;

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
        protocols: {CastProtocol.airplay},
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
    required String contentType,
    required Duration duration,
    Duration startPosition = Duration.zero,
  }) async {
    final session = await _service.connect(device);
    _session = session;
    try {
      final media = path.startsWith('http://') || path.startsWith('https://')
          ? CastMedia(
              url: path,
              type: CastMediaType.mp4,
              contentType: contentType,
              metadataType: 3,
              title: title,
              duration: duration,
              startPosition: startPosition,
            )
          : CastMedia.file(
              filePath: path,
              type: CastMediaType.mp4,
              contentType: contentType,
              metadataType: 3,
              title: title,
              duration: duration,
              startPosition: startPosition,
            );
      await session.loadMedia(media);
    } catch (_) {
      _session = null;
      await session.disconnect();
      rethrow;
    }
  }

  /// Pair an AirPlay 2 receiver using the PIN displayed by the receiver.
  /// Credentials are retained for the current app session and reused on the
  /// next connection to the same receiver.
  Future<void> pair(CastDevice device, String pin) async {
    final session = AirPlaySession(device);
    try {
      _credentials[device.id] = await session.pairSetup(pin);
    } finally {
      session.dispose();
    }
  }

  Future<void> pause() async => _session?.pause();
  Future<void> resume() async => _session?.play();
  Future<void> seek(Duration position) async => _session?.seek(position);
  Future<void> setVolume(double value) async => _session?.setVolume(value);
  Future<Duration?> getPosition() async => _session?.position;

  Future<void> stop() async {
    final session = _session;
    _session = null;
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

