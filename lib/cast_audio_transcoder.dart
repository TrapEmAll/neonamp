import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'chromecast_cast.dart';

/// Prepares a local file for receivers with a narrow audio codec whitelist.
/// Network URLs and content-provider URIs are deliberately left untouched.
Future<String?> prepareCastAudio(String path) async {
  if (audioContentType(path) != null || !_isLocalFile(path)) return null;

  final outputPath =
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'neonamp-cast-audio-${DateTime.now().microsecondsSinceEpoch}.wav';
  try {
    final session = await FFmpegKit.executeWithArguments([
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-vn',
      '-c:a',
      'pcm_s16le',
      '-ar',
      '44100',
      '-ac',
      '2',
      '-f',
      'wav',
      outputPath,
    ]);
    final output = File(outputPath);
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode) ||
        !await output.exists() ||
        await output.length() <= 44) {
      final details = (await session.getOutput())?.trim();
      throw StateError(
        'Could not prepare this audio file for casting'
        '${details == null || details.isEmpty ? '.' : ': ${_tail(details)}'}',
      );
    }
    return outputPath;
  } on Object {
    final output = File(outputPath);
    if (await output.exists()) await output.delete();
    rethrow;
  }
}

bool _isLocalFile(String path) {
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) return File(path).existsSync();
  final uri = Uri.tryParse(path);
  if (uri != null && uri.scheme.isNotEmpty && uri.scheme != 'file') {
    return false;
  }
  return File(path).existsSync();
}

String _tail(String value) =>
    value.length > 500 ? value.substring(value.length - 500) : value;

