String formatTrimTime(Duration value) {
  final seconds = value.inMilliseconds / 1000;
  return seconds.toStringAsFixed(3);
}

bool isValidTrimRange(Duration start, Duration end, Duration duration) =>
    start >= Duration.zero &&
    end > start &&
    end <= duration;

List<String> buildAudioTrimArguments({
  required String inputPath,
  required String outputPath,
  required Duration start,
  required Duration end,
}) {
  if (!isValidTrimRange(start, end, end)) {
    throw ArgumentError('The trim end must be after the start.');
  }
  return [
    '-nostdin',
    '-hide_banner',
    '-loglevel',
    'error',
    '-y',
    '-ss',
    formatTrimTime(start),
    '-i',
    inputPath,
    '-t',
    formatTrimTime(end - start),
    '-map',
    '0:a:0',
    '-vn',
    '-c:a',
    'pcm_s16le',
    '-f',
    'wav',
    outputPath,
  ];
}
