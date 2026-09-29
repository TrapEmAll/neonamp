Map<String, String> parseCustomMetadata(String text) {
  final result = <String, String>{};
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    final value = line.substring(separator + 1).trim();
    if (key.isEmpty || key.length > 80 || value.length > 500) continue;
    result[key] = value;
  }
  return result;
}

String serializeCustomMetadata(Map<String, String> fields) => fields.entries
    .map((entry) => entry.key + '=' + entry.value)
    .join('\n');

bool customMetadataMatches(
  Map<String, String> fields,
  String expression,
) {
  final separator = expression.indexOf('=');
  if (separator <= 0) return false;
  final key = expression.substring(0, separator).trim().toLowerCase();
  final expected = expression.substring(separator + 1).trim().toLowerCase();
  return fields.entries.any(
    (entry) =>
        entry.key.toLowerCase() == key &&
        entry.value.toLowerCase() == expected,
  );
}
