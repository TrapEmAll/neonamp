import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/play_history.dart';

void main() {
  const entries = [
    <String, Object?>{
      'playedAt': '2026-09-30T12:00:00Z',
      'title': 'A, B',
      'artist': 'The "Band"',
      'album': 'Live',
      'path': '/music/track.mp3',
    },
  ];

  test('exports versioned JSON history', () {
    final decoded = jsonDecode(encodePlayHistoryJson(entries)) as Map;
    expect(decoded['format'], 'neonamp-play-history');
    expect(decoded['version'], 1);
    expect((decoded['entries'] as List).single['title'], 'A, B');
  });

  test('escapes CSV commas and quotes', () {
    final csv = encodePlayHistoryCsv(entries);
    expect(csv, contains('"A, B"'));
    expect(csv, contains('"The ""Band"""'));
    expect(csv.split('\n').length, 3);
  });
}
