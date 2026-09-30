import 'dart:convert';

/// Builds a portable JSON document from the ordered listening history.
String encodePlayHistoryJson(Iterable<Map<String, Object?>> entries) =>
    jsonEncode({
      'format': 'neonamp-play-history',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'entries': entries.toList(growable: false),
    });

/// Builds a spreadsheet-friendly CSV document from the ordered listening history.
String encodePlayHistoryCsv(Iterable<Map<String, Object?>> entries) {
  final rows = <List<String>>[
    ['playedAt', 'title', 'artist', 'album', 'path'],
  ];
  for (final entry in entries) {
    rows.add([
      '${entry['playedAt'] ?? ''}',
      '${entry['title'] ?? ''}',
      '${entry['artist'] ?? ''}',
      '${entry['album'] ?? ''}',
      '${entry['path'] ?? ''}',
    ]);
  }
  return rows.map((row) => row.map(_csvCell).join(',')).join('\n') + '\n';
}

String _csvCell(String value) {
  final escaped = value.replaceAll('"', '""');
  return '"$escaped"';
}
