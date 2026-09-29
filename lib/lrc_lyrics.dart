import 'dart:math' as math;

class LrcLine {
  const LrcLine({required this.position, required this.text});
  final Duration position;
  final String text;
}

List<LrcLine> parseLrcLyrics(String source) {
  final lines = <LrcLine>[];
  final timeTag = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  for (final raw in source.split('\n')) {
    final matches = timeTag.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    final text = raw.substring(matches.last.end).trim();
    for (final match in matches) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3);
      final milliseconds = fraction == null
          ? 0
          : int.parse(fraction.padRight(3, '0').substring(0, 3));
      lines.add(
        LrcLine(
          position: Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: milliseconds,
          ),
          text: text,
        ),
      );
    }
  }
  lines.sort((a, b) => a.position.compareTo(b.position));
  return lines;
}

int activeLrcLine(List<LrcLine> lines, Duration position) {
  if (lines.isEmpty) return -1;
  var low = 0;
  var high = lines.length - 1;
  var active = -1;
  while (low <= high) {
    final middle = (low + high) ~/ 2;
    if (lines[middle].position <= position) {
      active = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return active;
}

bool hasLrcTimestamps(String text) => parseLrcLyrics(text).isNotEmpty;

double lrcScrollOffset(int index, double rowExtent, double viewportExtent) =>
    math.max(0, index * rowExtent - viewportExtent / 2 + rowExtent / 2);
