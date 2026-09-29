import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

class GoogleCastArtworkServer {
  HttpServer? _server;

  Future<List<Map<String, dynamic>>> attachQueue(
    List<Map<String, dynamic>> items,
  ) async {
    await close();
    final artworkItems = <int, Uint8List>{};
    final mediaItems = <int, File>{};
    for (var index = 0; index < items.length; index++) {
      final artwork = items[index]['artwork'];
      if (artwork is Uint8List &&
          artwork.isNotEmpty &&
          artwork.length <= 8 * 1024 * 1024) {
        artworkItems[index] = artwork;
      }
      final localPath = items[index]['localPath'];
      if (localPath is String && localPath.isNotEmpty) {
        final file = File(localPath);
        if (await file.exists()) mediaItems[index] = file;
      }
    }
    if (artworkItems.isEmpty && mediaItems.isEmpty) {
      return items
          .map((item) => <String, dynamic>{...item}..remove('artwork'))
          .toList();
    }

    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final address = interfaces
          .expand((interface) => interface.addresses)
          .firstWhere((candidate) => !candidate.isLoopback)
          .address;
      final token = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      _server = server;
      unawaited(
        server.forEach((request) async {
          final match = RegExp('^/$token/(art|media)/(\\d+)$')
              .firstMatch(request.uri.path);
          final kind = match?.group(1);
          final index = match == null ? null : int.tryParse(match.group(2)!);
          if (kind == 'art' && index != null) {
            final bytes = artworkItems[index];
            if (bytes != null && request.method == 'GET') {
              request.response
                ..statusCode = HttpStatus.ok
                ..headers.contentType = ContentType('image', 'jpeg')
                ..headers.contentLength = bytes.length;
              await request.response.addStream(
                Stream<List<int>>.value(bytes),
              );
              await request.response.close();
              return;
            }
          }
          if (kind == 'media' && index != null) {
            final file = mediaItems[index];
            if (file != null &&
                (request.method == 'GET' || request.method == 'HEAD')) {
              await _serveMedia(request, file);
              return;
            }
          }
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }).catchError((_) {}),
      );
      return items.asMap().entries.map((entry) {
        final item = <String, dynamic>{...entry.value};
        if (mediaItems.containsKey(entry.key)) {
          item['url'] =
              'http://$address:${server!.port}/$token/media/${entry.key}';
        }
        if (artworkItems.containsKey(entry.key)) {
          item['artworkUrl'] =
              'http://$address:${server!.port}/$token/art/${entry.key}';
        }
        item
          ..remove('localPath')
          ..remove('artwork');
        return item;
      }).toList();
    } on Object {
      await server?.close(force: true);
      _server = null;
      return items
          .map((item) => <String, dynamic>{...item}..remove('localPath'))
          .toList();
    }
  }

  Future<List<Map<String, dynamic>>> attachArtwork(
    List<Map<String, dynamic>> items,
  ) => attachQueue(items);

  Future<void> _serveMedia(HttpRequest request, File file) async {
    final length = await file.length();
    if (length <= 0) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    var start = 0;
    var end = length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      if (match == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      final requestedStart = int.tryParse(match.group(1)!);
      final requestedEnd = int.tryParse(match.group(2)!);
      if (requestedStart == null) {
        final suffix = requestedEnd ?? 0;
        if (suffix <= 0) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        start = math.max(0, length - suffix).toInt();
      } else {
        start = requestedStart;
        end = requestedEnd == null ? end : math.min(end, requestedEnd).toInt();
      }
      if (start >= length || start > end) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    request.response.headers
      ..set(HttpHeaders.contentTypeHeader, _mediaContentType(file.path))
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = end - start + 1;
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await request.response.addStream(file.openRead(start, end + 1));
    await request.response.close();
  }

  String _mediaContentType(String path) {
    switch (path.split('.').last.toLowerCase()) {
      case 'flac':
        return 'audio/flac';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      default:
        return 'audio/mpeg';
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }
}

class GoogleCast {
  static const MethodChannel _channel = MethodChannel('neonamp/cast');

  Future<void> showPicker() async {
    await _channel.invokeMethod<bool>('showPicker');
  }

  Future<Map<Object?, Object?>?> state() =>
      _channel.invokeMapMethod<Object?, Object?>('state');

  Future<bool> cast({
    required String path,
    required String title,
    required String artist,
    required String album,
    required Duration duration,
  }) async {
    final uri = Uri.tryParse(path);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError('Google Cast requires an HTTP(S) media URL.');
    }
    return await _channel.invokeMethod<bool>('cast', {
          'url': path,
          'title': title,
          'artist': artist,
          'album': album,
          'durationMs': duration.inMilliseconds,
          'contentType': _contentType(path),
        }) ??
        false;
  }

  Future<bool> castQueue({
    required List<Map<String, dynamic>> items,
    required int startIndex,
  }) async {
    if (items.isEmpty || startIndex < 0 || startIndex >= items.length) {
      return false;
    }
    for (final item in items) {
      final uri = Uri.tryParse(item['url']?.toString() ?? '');
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        throw StateError('Google Cast requires HTTP(S) media URLs for the entire queue.');
      }
    }
    final normalizedItems = items
        .map(
          (item) => <String, dynamic>{
            ...item,
            'contentType': item['contentType'] ?? _contentType(item['url'].toString()),
          },
        )
        .toList();
    return await _channel.invokeMethod<bool>('castQueue', {
          'items': normalizedItems,
          'startIndex': startIndex,
        }) ??
        false;
  }

  Future<void> pause() => _channel.invokeMethod<void>('pause');
  Future<void> resume() => _channel.invokeMethod<void>('resume');
  Future<void> stop() => _channel.invokeMethod<void>('stop');
  Future<void> next() => _channel.invokeMethod<void>('next');
  Future<void> previous() => _channel.invokeMethod<void>('previous');
  Future<void> seek(Duration position) => _channel.invokeMethod<void>('seek', {
        'positionMs': position.inMilliseconds,
      });
  Future<void> setVolume(double volume) =>
      _channel.invokeMethod<void>('setVolume', {'volume': volume});

  String _contentType(String path) {
    switch (path.split('?').first.split('.').last.toLowerCase()) {
      case 'flac':
        return 'audio/flac';
      case 'ogg':
      case 'oga':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      default:
        return 'audio/mpeg';
    }
  }
}
