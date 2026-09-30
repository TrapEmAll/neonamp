/// Returns the seek target when an A–B loop should wrap, or null otherwise.
Duration? abLoopSeekTarget({
  required bool enabled,
  required Duration? start,
  required Duration? end,
  required Duration position,
}) {
  if (!enabled || start == null || end == null || end <= start) return null;
  return position >= end ? start : null;
}

({Duration start, Duration end})? normalizedAbLoop(
  Duration? first,
  Duration? second,
) {
  if (first == null || second == null || first == second) return null;
  final start = first <= second ? first : second;
  final end = first <= second ? second : first;
  return (start: start, end: end);
}

String formatAbLoopDuration(Duration value) {
  final minutes = value.inMinutes.toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
