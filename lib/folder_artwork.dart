import 'dart:io';
import 'dart:typed_data';

const _folderArtworkNames = <String>{
  'cover',
  'folder',
  'front',
  'albumart',
  'album-art',
};

const _folderArtworkExtensions = <String>{'jpg', 'jpeg', 'png', 'webp'};

Future<Uint8List?> findFolderArtwork(
  String audioPath, {
  int maxBytes = 4 * 1024 * 1024,
}) async {
  final source = File(audioPath);
  if (!await source.exists()) return null;
  final directory = source.parent;
  final candidates = <File>[];
  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final stem = name.substring(0, dot).toLowerCase();
      final extension = name.substring(dot + 1).toLowerCase();
      if (_folderArtworkNames.contains(stem) &&
          _folderArtworkExtensions.contains(extension)) {
        candidates.add(entity);
      }
    }
  } on FileSystemException {
    return null;
  }
  candidates.sort((left, right) {
    final leftName = left.uri.pathSegments.last.toLowerCase();
    final rightName = right.uri.pathSegments.last.toLowerCase();
    final leftRank = _folderArtworkNames.toList().indexWhere(
      (value) => leftName.startsWith('$value.'),
    );
    final rightRank = _folderArtworkNames.toList().indexWhere(
      (value) => rightName.startsWith('$value.'),
    );
    return leftRank.compareTo(rightRank);
  });
  for (final candidate in candidates) {
    try {
      if (await candidate.length() > maxBytes) continue;
      return await candidate.readAsBytes();
    } on FileSystemException {
      continue;
    }
  }
  return null;
}
