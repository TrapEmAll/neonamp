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

/// Parses FFmpeg ffmetadata chapter blocks into the same virtual-track model
/// used by external CUE sheets.
List<CueTrackEntry> parseEmbeddedChapters(
  String contents,
  String sourcePath,
) {
  final entries = <CueTrackEntry>[];
  String? timebase;
  int? start;
  int? end;
  String? title;

  void flush() {
    if (start == null) return;
    final base = _parseTimebase(timebase ?? '1/1000');
    final startDuration = _chapterDuration(start!, base);
    final endDuration = end == null ? null : _chapterDuration(end!, base);
    if (endDuration != null && endDuration <= startDuration) {
      throw const FormatException('Embedded chapter ends before it starts');
    }
    entries.add(
      CueTrackEntry(
        filePath: sourcePath,
        sourceFileName: _cueBasename(sourcePath),
        trackNumber: entries.length + 1,
        start: startDuration,
        end: endDuration,
        title: title,
        performer: null,
        album: null,
      ),
    );
    timebase = null;
    start = null;
    end = null;
    title = null;
  }

  for (final raw in contents.split(RegExp(r'\\r?\\n'))) {
    final line = raw.trim();
    if (line == '[CHAPTER]') {
      flush();
      continue;
    }
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).toUpperCase();
    final value = _unescapeMetadataValue(line.substring(separator + 1));
    switch (key) {
      case 'TIMEBASE':
        timebase = value;
      case 'START':
        start = int.tryParse(value);
      case 'END':
        end = int.tryParse(value);
      case 'TITLE':
        title = value.trim().isEmpty ? null : value.trim();
    }
  }
  flush();
  if (entries.isEmpty) {
    throw const FormatException('Embedded metadata has no valid chapters');
  }
  return entries;
}

(int, int) _parseTimebase(String value) {
  final parts = value.split('/');
  final numerator = parts.length == 2 ? int.tryParse(parts[0]) : null;
  final denominator = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (numerator == null || numerator <= 0 || denominator == null || denominator <= 0) {
    throw const FormatException('Invalid embedded chapter timebase');
  }
  return (numerator, denominator);
}

Duration _chapterDuration(int value, (int, int) timebase) => Duration(
      microseconds: value * timebase.$1 * 1000000 ~/ timebase.$2,
    );

String _unescapeMetadataValue(String value) => value.replaceAllMapped(
      RegExp(r'\\(.)'),
      (match) => match.group(1)!,
    );

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
