import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:upnp_client/didl.dart';
import 'package:upnp_client/upnp_client.dart';

class DlnaCast {
  static const MethodChannel _androidChannel = MethodChannel('neonamp/dlna');
  HttpServer? _server;
  MediaRenderer? _renderer;
  DeviceDiscoverer? _discoverer;
  Duration _segmentStart = Duration.zero;
  Duration? _segmentEnd;

  bool get isConnected => _renderer != null;
  String? get rendererName => _renderer?.description?.friendlyName;

  Future<List<MediaRenderer>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (Platform.isAndroid &&
        await _androidChannel.invokeMethod<bool>('beginDiscovery') != true) {
      throw StateError('Nearby devices permission was not granted.');
    }
    final discoverer = DeviceDiscoverer();
    _discoverer = discoverer;
    try {
      await discoverer.start(addressTypes: [InternetAddressType.IPv4]);
      final devices = await discoverer.getDevices(
        searchTarget: UpnpDeviceType.mediaRenderer.urn(),
        timeout: timeout,
      );
      return devices.whereType<MediaRenderer>().toList();
    } finally {
      discoverer.stop();
      if (identical(_discoverer, discoverer)) _discoverer = null;
      if (Platform.isAndroid) {
        await _androidChannel.invokeMethod<void>('endDiscovery');
      }
    }
  }

  Future<void> play({
    required MediaRenderer renderer,
    required String path,
    required String title,
    required String artist,
    required String album,
    required Duration duration,
    Duration segmentStart = Duration.zero,
    Duration? segmentEnd,
  }) async {
    final transport = renderer.avTransport;
    if (transport == null) throw StateError('This device cannot play media.');
    if (segmentStart.isNegative ||
        (segmentEnd != null && segmentEnd <= segmentStart)) {
      throw ArgumentError('The media segment boundaries are invalid.');
    }
    final isUrl = path.startsWith('http://') || path.startsWith('https://');
    final uri = isUrl ? path : await _serveFile(path, renderer);
    final mime = _mimeType(path);
    final track = MusicTrack(
      id: '0',
      uri: uri,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      artUri: null,
      protocolInfo: 'http-get:*:$mime:*',
    );
    try {
      await transport.setAVTransportURI(uri, metadata: track.toXml());
      await transport.play();
      if (segmentStart > Duration.zero) {
        await transport.seek(SeekMode.relTime, _formatDlnaTime(segmentStart));
      }
      _renderer = renderer;
      _segmentStart = segmentStart;
      _segmentEnd = segmentEnd;
    } catch (_) {
      try {
        await transport.stop();
      } catch (_) {
        // Preserve the original playback error; some renderers reject Stop
        // while they are still preparing the new media resource.
      }
      if (!isUrl) {
        await _server?.close(force: true);
        _server = null;
      }
      rethrow;
    }
  }

  Future<String> _serveFile(String path, MediaRenderer renderer) async {
    await _server?.close(force: true);
    final file = File(path);
    final length = await file.length();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    final token = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    unawaited(
      server.forEach((request) async {
        if (request.uri.path != '/$token' ||
            (request.method != 'GET' && request.method != 'HEAD')) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final range = parseDlnaByteRange(
          request.headers.value(HttpHeaders.rangeHeader),
          length,
        );
        if (range == null) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$length',
          );
          await request.response.close();
          return;
        }
        final (start, end, partial) = range;
        request.response.statusCode = partial
            ? HttpStatus.partialContent
            : HttpStatus.ok;
        request.response.headers
          ..set(HttpHeaders.contentTypeHeader, _mimeType(path))
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentLengthHeader, end - start + 1)
          ..set('transferMode.dlna.org', 'Streaming');
        if (partial)
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$length',
          );
        if (request.method == 'HEAD') {
          await request.response.close();
          return;
        }
        try {
          await request.response.addStream(file.openRead(start, end + 1));
          await request.response.close();
        } catch (_) {
          await request.response.close();
        }
      }),
    );

    final remoteAddress = Uri.tryParse(renderer.url ?? '')?.host;
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final routes = interfaces
        .expand((i) => i.addresses)
        .where((address) => !address.address.startsWith('127.'))
        .where(
          (address) =>
              remoteAddress != null &&
              _sameSubnet(address.address, address.prefixLength, remoteAddress),
        )
        .toList();
    final route = routes.isEmpty ? null : routes.first;
    if (route == null) {
      await server.close(force: true);
      _server = null;
      throw StateError('Could not find a local network route to this player.');
    }
    return 'http://${route.address}:${server.port}/$token';
  }

  static (int, int, bool)? parseDlnaByteRange(String? header, int length) {
    if (length <= 0) return null;
    if (header == null) return (0, length - 1, false);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    if (startText.isEmpty && endText.isEmpty) return null;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      return (math.max(0, length - suffix), length - 1, true);
    }
    final start = int.tryParse(startText);
    final requestedEnd = endText.isEmpty ? length - 1 : int.tryParse(endText);
    if (start == null ||
        requestedEnd == null ||
        start >= length ||
        start > requestedEnd)
      return null;
    return (start, math.min(requestedEnd, length - 1), true);
  }

  static bool _sameSubnet(String local, int prefixLength, String remote) {
    final localOctets = local.split('.').map(int.tryParse).toList();
    final remoteOctets = remote.split('.').map(int.tryParse).toList();
    if (localOctets.length != 4 ||
        remoteOctets.length != 4 ||
        prefixLength < 0 ||
        prefixLength > 32)
      return false;
    if (localOctets.any((part) => part == null || part < 0 || part > 255) ||
        remoteOctets.any((part) => part == null || part < 0 || part > 255))
      return false;
    final localValue = localOctets.fold(
      0,
      (value, part) => (value << 8) | part!,
    );
    final remoteValue = remoteOctets.fold(
      0,
      (value, part) => (value << 8) | part!,
    );
    final mask = prefixLength == 0
        ? 0
        : (0xffffffff << (32 - prefixLength)) & 0xffffffff;
    return (localValue & mask) == (remoteValue & mask);
  }

  static String _mimeType(String path) {
    final ext = path.split('?').first.split('.').last.toLowerCase();
    return const {
          'mp3': 'audio/mpeg',
          'm4a': 'audio/mp4',
          'mp4': 'audio/mp4',
          'aac': 'audio/aac',
          'wav': 'audio/wav',
          'wave': 'audio/wav',
          'flac': 'audio/flac',
          'ogg': 'audio/ogg',
          'oga': 'audio/ogg',
          'opus': 'audio/ogg',
          'wma': 'audio/x-ms-wma',
          'aiff': 'audio/aiff',
          'aif': 'audio/aiff',
        }[ext] ??
        'application/octet-stream';
  }

  Future<void> pause() async => _renderer?.avTransport?.pause();
  Future<void> resume() async => _renderer?.avTransport?.play();
  Future<void> seek(Duration position) async => _renderer?.avTransport?.seek(
    SeekMode.relTime,
    _formatDlnaTime(
      segmentToSourcePosition(position, _segmentStart, _segmentEnd),
    ),
  );
  Future<void> setVolume(double value) async {
    final control = _renderer?.renderingControl;
    if (control == null) return;
    await control.setVolume(volume: (value.clamp(0.0, 1.0) * 100).round());
  }

  Future<Duration?> getPosition() async {
    final value = await _renderer?.avTransport?.getPositionInfo();
    final sourcePosition = parseDlnaPosition(value?.relTime);
    if (sourcePosition == null) return null;
    return sourceToSegmentPosition(sourcePosition, _segmentStart, _segmentEnd);
  }

  static Duration? parseDlnaPosition(String? value) {
    final match = RegExp(r'^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$')
        .firstMatch(value?.trim() ?? '');
    if (match == null) return null;
    final hours = int.tryParse(match.group(1)!);
    final minutes = int.tryParse(match.group(2)!);
    final seconds = int.tryParse(match.group(3)!);
    if (hours == null ||
        minutes == null ||
        seconds == null ||
        minutes >= 60 ||
        seconds >= 60) {
      return null;
    }
    final fraction = match.group(4);
    final milliseconds = fraction == null
        ? 0
        : int.parse('${fraction}000'.substring(0, 3));
    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  static Duration sourceToSegmentPosition(
    Duration sourcePosition,
    Duration segmentStart,
    Duration? segmentEnd,
  ) {
    var relative = sourcePosition - segmentStart;
    if (relative.isNegative) relative = Duration.zero;
    final segmentDuration = segmentEnd == null
        ? null
        : segmentEnd - segmentStart;
    if (segmentDuration != null && relative > segmentDuration) {
      relative = segmentDuration;
    }
    return relative;
  }

  static Duration segmentToSourcePosition(
    Duration segmentPosition,
    Duration segmentStart,
    Duration? segmentEnd,
  ) {
    var relative = segmentPosition.isNegative ? Duration.zero : segmentPosition;
    final segmentDuration = segmentEnd == null
        ? null
        : segmentEnd - segmentStart;
    if (segmentDuration != null && relative > segmentDuration) {
      relative = segmentDuration;
    }
    return segmentStart + relative;
  }

  static String _formatDlnaTime(Duration value) =>
      '${value.inHours.toString().padLeft(2, '0')}:${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  Future<void> stop() async {
    try {
      await _renderer?.avTransport?.stop();
    } finally {
      _renderer = null;
      _segmentStart = Duration.zero;
      _segmentEnd = null;
      await _server?.close(force: true);
      _server = null;
    }
  }

  Future<void> dispose() async {
    await stop();
    _discoverer?.dispose();
    _discoverer = null;
  }
}
