/// Lightweight library statistics used by the maintenance screen.
class LibraryStatisticEntry {
  const LibraryStatisticEntry({required this.path, this.bytes = 0});

  final String path;
  final int bytes;
}

class LibraryStatistics {
  const LibraryStatistics({
    required this.totalTracks,
    required this.totalBytes,
    required this.tracksByFolder,
    required this.tracksByExtension,
  });

  final int totalTracks;
  final int totalBytes;
  final Map<String, int> tracksByFolder;
  final Map<String, int> tracksByExtension;
}

LibraryStatistics buildLibraryStatistics(Iterable<LibraryStatisticEntry> entries) {
  var totalTracks = 0;
  var totalBytes = 0;
  final tracksByFolder = <String, int>{};
  final tracksByExtension = <String, int>{};
  for (final entry in entries) {
    totalTracks++;
    totalBytes += entry.bytes < 0 ? 0 : entry.bytes;
    final normalized = entry.path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final folder = slash > 0 ? normalized.substring(0, slash) : 'Library root';
    tracksByFolder[folder] = (tracksByFolder[folder] ?? 0) + 1;
    final name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : 'unknown';
    tracksByExtension[extension] = (tracksByExtension[extension] ?? 0) + 1;
  }
  return LibraryStatistics(
    totalTracks: totalTracks,
    totalBytes: totalBytes,
    tracksByFolder: Map.unmodifiable(tracksByFolder),
    tracksByExtension: Map.unmodifiable(tracksByExtension),
  );
}
