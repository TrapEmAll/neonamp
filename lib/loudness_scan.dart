import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

final _ebur128IntegratedPattern = RegExp(
  r'\bI:\s*(-?(?:\d+(?:\.\d+)?|\.\d+))\s*LUFS',
  caseSensitive: false,
);

double? parseEbur128IntegratedLufs(String output) {
  double? last;
  for (final match in _ebur128IntegratedPattern.allMatches(output)) {
    final value = double.tryParse(match.group(1)!);
    if (value != null && value.isFinite) last = value;
  }
  return last;
}

Future<double?> measureIntegratedLufsWithFfmpeg(String path) async {
  if (path.startsWith('http://') || path.startsWith('https://')) return null;
  final input = File(path);
  if (!await input.exists()) return null;
  final session = await FFmpegKit.executeWithArguments([
    '-nostdin',
    '-hide_banner',
    '-loglevel',
    'info',
    '-i',
    path,
    '-filter_complex',
    'ebur128=framelog=verbose',
    '-f',
    'null',
    Platform.isWindows ? 'NUL' : '/dev/null',
  ]);
  final returnCode = await session.getReturnCode();
  if (!ReturnCode.isSuccess(returnCode)) return null;
  final logs = await session.getAllLogsAsString();
  final output = logs ?? await session.getOutput() ?? '';
  return parseEbur128IntegratedLufs(output);
}
