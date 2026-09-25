import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

class SilenceProfile {
  const SilenceProfile({this.leading = Duration.zero, this.trailing = Duration.zero});
  final Duration leading;
  final Duration trailing;
}

SilenceProfile parseSilenceDetect(String logs, {Duration? duration}) {
  final starts = <double>[];
  final ends = <double>[];
  for (final line in logs.split(RegExp(r'\r?\n'))) {
    final start = RegExp(r'silence_start:\s*([0-9.]+)').firstMatch(line);
    if (start != null) starts.add(double.parse(start.group(1)!));
    final end = RegExp(r'silence_end:\s*([0-9.]+)').firstMatch(line);
    if (end != null) ends.add(double.parse(end.group(1)!));
  }
  var leading = 0.0;
  if (starts.isNotEmpty && starts.first <= 0.05 && ends.isNotEmpty) {
    leading = ends.first;
  }
  var trailing = 0.0;
  if (duration != null && starts.isNotEmpty) {
    final lastStart = starts.last;
    final hasEndAfterLastStart = ends.any((end) => end > lastStart);
    if (!hasEndAfterLastStart && duration.inMicroseconds > lastStart * 1000000) {
      trailing = duration.inMicroseconds / 1000000 - lastStart;
    }
  }
  return SilenceProfile(
    leading: Duration(microseconds: (leading * 1000000).round()),
    trailing: Duration(microseconds: (trailing * 1000000).round()),
  );
}

Duration adjustSilenceAwareCrossfade({
  required Duration base,
  required SilenceProfile outgoing,
  required SilenceProfile incoming,
}) {
  final milliseconds = base.inMilliseconds +
      incoming.leading.inMilliseconds -
      outgoing.trailing.inMilliseconds;
  return Duration(milliseconds: milliseconds.clamp(500, 12000));
}

Future<SilenceProfile?> detectSilenceWithFfmpeg(
  String path, {
  Duration? duration,
}) async {
  try {
    final session = await FFmpegKit.executeWithArguments([
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'info',
      '-i',
      path,
      '-af',
      'silencedetect=noise=-35dB:d=0.25',
      '-f',
      'null',
      Platform.isWindows ? 'NUL' : '/dev/null',
    ]);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) return null;
    final logs = await session.getAllLogsAsString() ?? await session.getOutput() ?? '';
    return parseSilenceDetect(logs, duration: duration);
  } on Object {
    return null;
  }
}
