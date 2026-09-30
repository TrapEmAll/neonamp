/// Normalized payloads delivered to Flutter from Android share/open-with
/// intents.
class AndroidExternalIntent {
  const AndroidExternalIntent({
    required this.path,
    this.name,
  });

  final String path;
  final String? name;

  bool get isRemoteUrl {
    final scheme = Uri.tryParse(path)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }
}

List<AndroidExternalIntent> deduplicateAndroidExternalIntents(
  Iterable<AndroidExternalIntent> intents,
) {
  final seen = <String>{};
  final result = <AndroidExternalIntent>[];
  for (final intent in intents) {
    final path = intent.path.trim();
    if (path.isEmpty || !seen.add(path)) continue;
    result.add(
      AndroidExternalIntent(
        path: path,
        name: intent.name?.trim().isEmpty == true ? null : intent.name?.trim(),
      ),
    );
  }
  return result;
}
