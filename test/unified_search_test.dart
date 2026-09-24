import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/unified_search.dart';

void main() {
  const items = [
    UnifiedSearchItem(
      id: '1',
      title: 'Neon Lights',
      artist: 'Artist',
      album: 'Album',
      source: 'Local',
    ),
    UnifiedSearchItem(
      id: 'remote-1',
      title: 'Night Drive',
      artist: 'Remote Artist',
      album: 'Remote Album',
      source: 'Navidrome',
    ),
  ];

  test('unified search matches title, artist, and album case-insensitively', () {
    expect(filterUnifiedSearch(items, 'NEON').single.id, '1');
    expect(filterUnifiedSearch(items, 'remote artist').single.id, 'remote-1');
    expect(filterUnifiedSearch(items, 'missing'), isEmpty);
    expect(filterUnifiedSearch(items, ' '), hasLength(2));
  });

  test('deduplicates within each source while preserving source boundaries', () {
    final results = deduplicateUnifiedSearch([
      ...items,
      items[0],
      const UnifiedSearchItem(
        id: '1',
        title: 'Remote copy',
        artist: 'Artist',
        album: 'Album',
        source: 'Navidrome',
      ),
    ]);
    expect(results, hasLength(3));
    expect(results[0].source, 'Local');
    expect(results[2].source, 'Navidrome');
  });
}
