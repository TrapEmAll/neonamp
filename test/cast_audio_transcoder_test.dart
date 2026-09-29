import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/cast_audio_transcoder.dart';

void main() {
  test('leaves already receiver-compatible local audio unchanged', () async {
    final file = File('${Directory.systemTemp.path}/neonamp-test.mp3');
    await file.writeAsBytes(<int>[0]);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    expect(await prepareCastAudio(file.path), isNull);
  });

  test('does not try to transcode remote or provider URIs', () async {
    expect(await prepareCastAudio('content://media/external/audio/1'), isNull);
    expect(await prepareCastAudio('https://example.com/audio.wma'), isNull);
  });
}

