import 'dart:convert';

const neonAmpBackupFormat = 'neonamp-backup';
const neonAmpBackupVersion = 1;

String encodeNeonAmpBackup(Map<String, Object?> state) => jsonEncode({
  'format': neonAmpBackupFormat,
  'version': neonAmpBackupVersion,
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'state': state,
});

Map<String, dynamic> decodeNeonAmpBackup(String contents) {
  final decoded = jsonDecode(contents);
  if (decoded is! Map) {
    throw const FormatException('NeonAmp backup must contain a JSON object.');
  }
  if (decoded['format'] != neonAmpBackupFormat) {
    throw const FormatException('This file is not a NeonAmp backup.');
  }
  if (decoded['version'] is! num ||
      (decoded['version'] as num).toInt() > neonAmpBackupVersion) {
    throw const FormatException('This backup was created by a newer NeonAmp.');
  }
  final state = decoded['state'];
  if (state is! Map) {
    throw const FormatException('NeonAmp backup has no state payload.');
  }
  return Map<String, dynamic>.from(state);
}
