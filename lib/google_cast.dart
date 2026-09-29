import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class GoogleCastArtworkServer {
  HttpServer? _server;

  Future<List<Map<String, dynamic>>> attachArtwork(
    List<Map<String, dynamic>> items,
  ) async {
    await close();
    final artworkItems = <int, Uint8List>{};
    for (var index = 0; index < items.length; index++) {
      final bytes = items[index]['artwork'];
      if (bytes is Uint8List && bytes.isNotEmpty && bytes.length <= 8 * 1024 * 1024) {
        artworkItems[index] = bytes;
      }
    }
    if (artworkItems.isEmpty) return items;

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
          final match = RegExp('^/$token/(\\d+)$').firstMatch(request.uri.path);
          final index = match == null ? null : int.tryParse(match.group(1)!);
          final bytes = index == null ? null : artworkItems[index];
          if (bytes == null || request.method != 'GET') {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType('image', 'jpeg')
            ..headers.contentLength = bytes.length;
          await request.response.addStream(Stream<List<int>>.value(bytes));
          await request.response.close();
        }).catchError((_) {}),
      );
      return items.asMap().entries.map((entry) {
        final item = <String, dynamic>{...entry.value};
        if (artworkItems.containsKey(entry.key)) {
          item['artworkUrl'] = 'http://$address:${server!.port}/$token/${entry.key}';
        }
        item.remove('artwork');
        return item;
      }).toList();
    } on Object {
      await server?.close(force: true);
      _server = null;
      return items;
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
