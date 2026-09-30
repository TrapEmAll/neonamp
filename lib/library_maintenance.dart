class LibraryMaintenanceReport {
  const LibraryMaintenanceReport({
    required this.missingPaths,
    required this.duplicatePaths,
  });

  final List<String> missingPaths;
  final List<String> duplicatePaths;

  bool get isClean => missingPaths.isEmpty && duplicatePaths.isEmpty;
}

/// Returns paths that no longer resolve to a local file.
List<String> findMissingLibraryPaths(
  Iterable<String> paths,
  Set<String> existingPaths,
) => paths
    .where((path) => path.trim().isNotEmpty && !existingPaths.contains(path))
    .toList(growable: false);

/// Finds duplicate library entries while keeping the first occurrence as the
/// canonical entry. This is deliberately path-based: two files with the same
/// tags are not duplicates and must remain available for quality comparison.
List<String> findDuplicateLibraryPaths(Iterable<String> paths) {
  final seen = <String>{};
  final duplicates = <String>[];
  for (final path in paths) {
    if (!seen.add(path)) duplicates.add(path);
  }
  return duplicates;
}

List<String> removeDuplicateLibraryPaths(Iterable<String> paths) {
  final seen = <String>{};
  return paths.where(seen.add).toList(growable: false);
}

LibraryMaintenanceReport buildLibraryMaintenanceReport({
  required Iterable<String> libraryPaths,
  required Set<String> existingPaths,
}) {
  final paths = libraryPaths.toList(growable: false);
  return LibraryMaintenanceReport(
    missingPaths: findMissingLibraryPaths(paths, existingPaths),
    duplicatePaths: findDuplicateLibraryPaths(paths),
  );
}
