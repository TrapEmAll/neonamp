/// Models and helpers for the Android MediaStore library source.
///
/// The native side returns cached, readable paths so the rest of NeonAmp can
/// use the same metadata and DSP pipeline as SAF folders.
class AndroidMediaStoreTrack {
  const AndroidMediaStoreTrack({
    required this.path,
    required this.name,
    required this.relativePath,
  });

  final String path;
  final String name;
  final String relativePath;

  factory AndroidMediaStoreTrack.fromMap(Map<Object?, Object?> value) {
    final path = value['path'] as String?;
    if (path == null || path.isEmpty) {
      throw const FormatException('MediaStore result is missing its cached path.');
    }
    final name = value['name'] as String?;
    return AndroidMediaStoreTrack(
      path: path,
      name: name == null || name.isEmpty ? path : name,
      relativePath: value['relativePath'] as String? ?? name ?? path,
    );
  }
}

List<AndroidMediaStoreTrack> deduplicateAndroidMediaStoreTracks(
  Iterable<AndroidMediaStoreTrack> tracks,
) {
  final seen = <String>{};
  return [
    for (final track in tracks)
      if (seen.add(track.path)) track,
  ];
}
