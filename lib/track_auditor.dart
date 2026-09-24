class AudioAuditEntry {
  const AudioAuditEntry({
    required this.path,
    required this.title,
    required this.artist,
    this.album = '',
    this.extension = '',
    this.sizeBytes = 0,
    this.bitrateKbps,
    this.peakDb,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final String extension;
  final int sizeBytes;
  final int? bitrateKbps;
  final double? peakDb;

  bool get isClipped => peakDb != null && peakDb! >= -0.1;

  bool get hasCoreTags =>
      title.trim().isNotEmpty &&
      artist.trim().isNotEmpty &&
      album.trim().isNotEmpty;

  String get duplicateKey =>
      _normalize(artist) + '\u0000' + _normalize(title);

  int get qualityScore {
    final bitrate = bitrateKbps ?? 0;
    final lossless = const {'flac', 'wav', 'aiff', 'aif', 'alac'}.contains(
      extension.toLowerCase(),
    );
    return (lossless ? 1000000 : 0) + bitrate * 1000 + sizeBytes ~/ 1000;
  }
}

class DuplicateAudioGroup {
  const DuplicateAudioGroup(this.entries);

  final List<AudioAuditEntry> entries;

  AudioAuditEntry get recommended =>
      entries.reduce((a, b) => a.qualityScore >= b.qualityScore ? a : b);

  List<AudioAuditEntry> get lowerQuality =>
      entries.where((entry) => !identical(entry, recommended)).toList();
}

List<DuplicateAudioGroup> findDuplicateAudioGroups(
  Iterable<AudioAuditEntry> entries,
) {
  final groups = <String, List<AudioAuditEntry>>{};
  for (final entry in entries) {
    if (entry.title.trim().isEmpty || entry.artist.trim().isEmpty) continue;
    groups.putIfAbsent(entry.duplicateKey, () => []).add(entry);
  }
  return groups.values
      .where((entries) => entries.length > 1)
      .map(DuplicateAudioGroup.new)
      .toList();
}

List<AudioAuditEntry> findClippedTracks(
  Iterable<AudioAuditEntry> entries,
) => entries.where((entry) => entry.isClipped).toList();

List<AudioAuditEntry> findMissingCoreTags(Iterable<AudioAuditEntry> entries) =>
    entries.where((entry) => !entry.hasCoreTags).toList();

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();
