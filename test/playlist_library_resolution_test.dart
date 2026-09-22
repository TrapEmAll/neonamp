import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/playlist_library_resolution.dart';

void main() {
  const relativePaths = {
    '/app/library/a.mp3': 'Albums/Live/a.mp3',
    '/app/library/b.mp3': 'Albums/Studio/b.mp3',
  };

  test('resolves relative playlist paths to cached library files', () {
    expect(
      resolvePlaylistLibraryPath(
        entryPath: r'Albums\Live\a.mp3',
        resolvedPath: '/tmp/import/a.mp3',
        libraryRelativePaths: relativePaths,
      ),
      '/app/library/a.mp3',
    );
  });

  test('uses a unique basename when playlist and library roots differ', () {
    expect(
      resolvePlaylistLibraryPath(
        entryPath: 'track.mp3',
        resolvedPath: '/tmp/import/track.mp3',
        libraryRelativePaths: const {
          '/app/library/track.mp3': 'Music/track.mp3',
        },
      ),
      '/app/library/track.mp3',
    );
  });

  test('does not guess when multiple library files have the same basename', () {
    expect(
      resolvePlaylistLibraryPath(
        entryPath: 'track.mp3',
        resolvedPath: '/tmp/import/track.mp3',
        libraryRelativePaths: const {
          '/app/library/one.mp3': 'Album One/track.mp3',
          '/app/library/two.mp3': 'Album Two/track.mp3',
        },
      ),
      isNull,
    );
  });
}
