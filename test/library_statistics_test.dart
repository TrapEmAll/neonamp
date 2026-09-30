import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/library_statistics.dart';

void main() {
  test('groups tracks by normalized folder and extension', () {
    final stats = buildLibraryStatistics([
      const LibraryStatisticEntry(path: r'C:\Music\Album\one.FLAC', bytes: 10),
      const LibraryStatisticEntry(path: 'C:/Music/Album/two.flac', bytes: 20),
      const LibraryStatisticEntry(path: 'stream://station/live', bytes: 999),
    ]);

    expect(stats.totalTracks, 3);
    expect(stats.totalBytes, 1029);
    expect(stats.tracksByFolder[r'C:/Music/Album'], 2);
    expect(stats.tracksByFolder['stream://station'], 1);
    expect(stats.tracksByExtension['flac'], 2);
    expect(stats.tracksByExtension['unknown'], 1);
  });

  test('clamps invalid byte counts', () {
    final stats = buildLibraryStatistics([
      const LibraryStatisticEntry(path: 'track.mp3', bytes: -1),
    ]);
    expect(stats.totalBytes, 0);
    expect(stats.tracksByFolder['Library root'], 1);
  });
}
