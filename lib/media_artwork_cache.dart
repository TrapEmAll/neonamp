import 'dart:io';
import 'dart:typed_data';

/// Stores embedded cover art as a local file for notification/media-session
/// consumers, which cannot consume the in-memory bytes on [Track].
Future<Uri?> cacheMediaArtwork(
  Uint8List? artwork, {
  required Directory directory,
}) async {
  if (artwork == null || artwork.isEmpty) return null;

  // A deterministic content key means repeat playback reuses the same file,
  // while different covers never overwrite each other.
  var hash = 0x811c9dc5;
  for (final byte in artwork) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  final name = 'neonamp-art-${hash.toRadixString(16)}-${artwork.length}.img';
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  if (await file.exists() && _sameBytes(await file.readAsBytes(), artwork)) {
    return file.uri;
  }

  await directory.create(recursive: true);
  final temporary = File(
    '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
  );
  await temporary.writeAsBytes(artwork, flush: true);
  try {
    if (await file.exists()) {
      if (_sameBytes(await file.readAsBytes(), artwork)) {
        await temporary.delete();
        return file.uri;
      }
      await file.delete();
    }
    await temporary.rename(file.path);
  } on FileSystemException {
    try {
      // Another session may have cached identical art concurrently.
      if (await file.exists() &&
          _sameBytes(await file.readAsBytes(), artwork)) {
        return file.uri;
      }
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
  return file.uri;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
