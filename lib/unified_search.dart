class UnifiedSearchItem {
  const UnifiedSearchItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.source,
    this.path,
    this.streamUrl,
    this.durationMs,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String source;
  final String? path;
  final String? streamUrl;
  final int? durationMs;

  String get searchText =>
      '$title $artist $album'.toLowerCase();

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'source': source,
    if (path != null) 'path': path,
    if (streamUrl != null) 'streamUrl': streamUrl,
    if (durationMs != null) 'durationMs': durationMs,
  };
}

List<UnifiedSearchItem> filterUnifiedSearch(
  Iterable<UnifiedSearchItem> items,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return items.toList();
  return items.where((item) => item.searchText.contains(normalized)).toList();
}

List<UnifiedSearchItem> deduplicateUnifiedSearch(
  Iterable<UnifiedSearchItem> items,
) {
  final seen = <String>{};
  final result = <UnifiedSearchItem>[];
  for (final item in items) {
    final key = '${item.source}:${item.id}';
    if (seen.add(key)) result.add(item);
  }
  return result;
}
