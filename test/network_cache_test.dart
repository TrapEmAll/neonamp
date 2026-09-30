import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/network_cache.dart';

void main() {
  test('uses a deterministic safe filename with the source extension', () {
    final name = networkCacheFileName('office/share', r'album\track.FLAC');
    expect(name, endsWith('.flac'));
    expect(name, isNot(contains('/')));
    expect(name, isNot(contains(r'\')));
    expect(name, networkCacheFileName('office/share', r'album\track.FLAC'));
  });

  test('falls back to an audio extension when the path has no filename suffix', () {
    expect(networkCacheFileName('server', 'music/live'), endsWith('.audio'));
  });

  test('accepts only non-trivial cached files', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-cache-test');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}track.mp3');
    await file.writeAsBytes(List<int>.filled(45, 1));
    expect(await isUsableNetworkCacheFile(file), isTrue);
    await file.writeAsBytes(List<int>.filled(44, 1));
    expect(await isUsableNetworkCacheFile(file), isFalse);
  });
}

