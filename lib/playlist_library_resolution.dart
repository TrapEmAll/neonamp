String? resolvePlaylistLibraryPath({
  required String entryPath,
  required String resolvedPath,
  required Map<String, String> libraryRelativePaths,
}) {
  if (libraryRelativePaths.containsKey(resolvedPath)) return resolvedPath;

  String normalize(String path) => path
      .replaceAll('\\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .join('/')
      .toLowerCase();

  final requested = normalize(entryPath);
  final exact = libraryRelativePaths.entries
      .where((entry) => normalize(entry.value) == requested)
      .map((entry) => entry.key)
      .toList();
  if (exact.length == 1) return exact.single;
  if (exact.length > 1) return null;

  final basename = requested.split('/').last;
  if (basename.isEmpty) return null;
  final sameName = libraryRelativePaths.entries
      .where((entry) => normalize(entry.value).split('/').last == basename)
      .map((entry) => entry.key)
      .toList();
  return sameName.length == 1 ? sameName.single : null;
}
