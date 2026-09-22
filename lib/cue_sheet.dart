import 'dart:io';

class CueTrackEntry {
  const CueTrackEntry({
    required this.filePath,
    required this.sourceFileName,
    required this.trackNumber,
    required this.start,
    required this.end,
    required this.title,
    required this.performer,
    required this.album,
  });

  final String filePath;
  final String sourceFileName;
  final int trackNumber;
  final Duration start;
  final Duration? end;
  final String? title;
  final String? performer;
  final String? album;
}

Duration cueRelativePosition(Duration sourcePosition, Duration start) {
  final position = sourcePosition - start;
  return position.isNegative ? Duration.zero : position;
}

Duration cueSegmentDuration(
  Duration sourceDuration, {
  required Duration start,
  Duration? end,
}) {
  final duration = (end ?? sourceDuration) - start;
  return duration.isNegative ? Duration.zero : duration;
}

/// Parses the common FILE/TRACK/TITLE/PERFORMER/INDEX 01 subset of CUE.
List<CueTrackEntry> parseCueSheet(String contents, String cueFilePath) {
  final albumTitle = <String>[];
  final albumPerformer = <String>[];
  final pending = <_CuePendingTrack>[];
  String? currentFile;
  _CuePendingTrack? currentTrack;

  String valueOf(String source) {
    final value = source.trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1).replaceAll('""', '"');
    }
    return value;
  }

  for (final raw in contents.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    final file = RegExp(
      r'^FILE\s+(.+?)\s+\S+\s*$',
      caseSensitive: false,
    ).firstMatch(line);
    if (file != null) {
      currentFile = valueOf(file.group(1)!);
      currentTrack = null;
      continue;
    }
    final track = RegExp(
      r'^TRACK\s+(\d+)\s+(\S+)',
      caseSensitive: false,
    ).firstMatch(line);
    if (track != null && currentFile != null) {
      currentTrack = _CuePendingTrack(
        filePath: _resolveCueFile(cueFilePath, currentFile),
        sourceFileName: _cueBasename(currentFile),
        number: int.parse(track.group(1)!),
        isAudio: track.group(2)!.toUpperCase() == 'AUDIO',
      );
      pending.add(currentTrack);
      continue;
    }
    final directive = RegExp(
      r'^(TITLE|PERFORMER)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (directive != null) {
      final kind = directive.group(1)!.toUpperCase();
      final value = valueOf(directive.group(2)!);
      if (currentTrack == null) {
        (kind == 'TITLE' ? albumTitle : albumPerformer).add(value);
      } else if (kind == 'TITLE') {
        currentTrack.title = value;
      } else {
        currentTrack.performer = value;
      }
      continue;
    }
    final index = RegExp(
      r'^INDEX\s+01\s+(\d+):(\d{2}):(\d{2})\s*$',
      caseSensitive: false,
    ).firstMatch(line);
    if (index != null && currentTrack != null) {
      final minutes = int.parse(index.group(1)!);
      final seconds = int.parse(index.group(2)!);
      final frames = int.parse(index.group(3)!);
      if (seconds >= 60 || frames >= 75) {
        throw const FormatException('Invalid CUE INDEX 01 timestamp');
      }
      currentTrack.start = Duration(
        milliseconds: ((minutes * 60 + seconds) * 1000 + frames * 1000 ~/ 75),
      );
    }
  }

  final audioTracks = pending.where((track) => track.isAudio);
  if (audioTracks.isEmpty || audioTracks.any((track) => track.start == null)) {
    throw const FormatException('CUE sheet has no playable INDEX 01 tracks');
  }
  final album = albumTitle.isEmpty ? null : albumTitle.last;
  final performer = albumPerformer.isEmpty ? null : albumPerformer.last;
  return [
    for (var i = 0; i < pending.length; i++)
      if (pending[i].isAudio)
        CueTrackEntry(
          filePath: pending[i].filePath,
          sourceFileName: pending[i].sourceFileName,
          trackNumber: pending[i].number,
          start: pending[i].start!,
          end: _nextTrackStart(pending, i),
          title: pending[i].title,
          performer: pending[i].performer ?? performer,
          album: album,
        ),
  ];
}

String _resolveCueFile(String cuePath, String source) {
  final windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(source);
  final normalized = source.replaceAll('\\', Platform.pathSeparator);
  if (File(source).isAbsolute || (Platform.isWindows && windowsAbsolute)) {
    return File(normalized).absolute.path;
  }
  final relativeSource = windowsAbsolute
      ? source.split(RegExp(r'[/\\]')).last
      : normalized;
  return File(
    '${File(cuePath).parent.path}${Platform.pathSeparator}$relativeSource',
  ).absolute.path;
}

String _cueBasename(String path) => path.split(RegExp(r'[/\\]')).last;

Duration? _nextTrackStart(List<_CuePendingTrack> tracks, int index) {
  final nextIndex = index + 1;
  if (nextIndex >= tracks.length ||
      tracks[nextIndex].filePath != tracks[index].filePath) {
    return null;
  }
  final end = tracks[nextIndex].start;
  final start = tracks[index].start!;
  if (end != null && end <= start) {
    throw const FormatException('CUE track indexes are not increasing');
  }
  return end;
}

class _CuePendingTrack {
  _CuePendingTrack({
    required this.filePath,
    required this.sourceFileName,
    required this.number,
    required this.isAudio,
  });

  final String filePath;
  final String sourceFileName;
  final int number;
  final bool isAudio;
  Duration? start;
  String? title;
  String? performer;
}
