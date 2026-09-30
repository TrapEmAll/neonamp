import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/android_media_store.dart';

void main() {
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
