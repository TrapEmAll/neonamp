import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/media_artwork_cache.dart';

void main() {
  test('bounds artwork payloads for widget and media-session IPC', () {
    final artwork = Uint8List.fromList([1, 2, 3]);

    expect(boundedMediaArtwork(artwork), same(artwork));
    expect(boundedMediaArtwork(artwork, maxBytes: 2), isNull);
    expect(boundedMediaArtwork(null), isNull);
  });

  test('caches cover bytes at a reusable local media URI', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-art-');
    addTearDown(() => directory.delete(recursive: true));
    final artwork = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);

    final first = await cacheMediaArtwork(artwork, directory: directory);
    final second = await cacheMediaArtwork(artwork, directory: directory);

    expect(first, isNotNull);
    expect(first, second);
    expect(first!.scheme, 'file');
    expect(await File.fromUri(first).readAsBytes(), artwork);
  });

  test('does not create a cache entry for absent artwork', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-art-');
    addTearDown(() => directory.delete(recursive: true));

    expect(await cacheMediaArtwork(null, directory: directory), isNull);
    expect(await directory.list().toList(), isEmpty);
  });
}
