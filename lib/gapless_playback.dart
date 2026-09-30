bool isGaplessLocalPath(String path) {
  final normalized = path.trim().toLowerCase();
  if (normalized.isEmpty ||
      normalized.startsWith('http://') ||
      normalized.startsWith('https://') ||
      normalized.startsWith('content://') ||
      normalized.startsWith('file://')) {
    return false;
  }
  return true;
}

bool canUseGaplessQueue(Iterable<String> paths) {
  final values = paths.toList(growable: false);
  return values.isNotEmpty && values.every(isGaplessLocalPath);
}
