import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/android_external_intent.dart';
import 'package:neonamp/android_media_store.dart';

void main() {
  test('deduplicates shared Android files and URLs', () {
    final result = deduplicateAndroidExternalIntents([
      const AndroidExternalIntent(path: ' /music/song.mp3 ', name: ' Song '),
      const AndroidExternalIntent(path: '/music/song.mp3'),
      const AndroidExternalIntent(path: 'https://radio.example/live'),
      const AndroidExternalIntent(path: 'https://radio.example/live'),
    ]);

    expect(result.map((item) => item.path), [
      '/music/song.mp3',
      'https://radio.example/live',
    ]);
    expect(result.first.name, 'Song');
    expect(result.last.isRemoteUrl, isTrue);
  });

  test('parses and deduplicates cached MediaStore results', () {
    final tracks = deduplicateAndroidMediaStoreTracks([
      AndroidMediaStoreTrack.fromMap({
        'path': '/cache/a.mp3',
        'name': 'A.mp3',
        'relativePath': 'Music/A.mp3',
      }),
      AndroidMediaStoreTrack.fromMap({
        'path': '/cache/a.mp3',
        'name': 'A.mp3',
        'relativePath': 'Music/A.mp3',
      }),
    ]);
    expect(tracks, hasLength(1));
    expect(tracks.single.relativePath, 'Music/A.mp3');
  });
}
