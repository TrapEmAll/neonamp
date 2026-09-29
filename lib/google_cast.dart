import 'package:flutter/services.dart';

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
