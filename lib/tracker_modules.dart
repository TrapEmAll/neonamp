import 'package:flutter/services.dart';

const trackerModuleExtensions = <String>{
  '669',
  'amf',
  'ams',
  'dbm',
  'dmf',
  'dsm',
  'far',
  'gdm',
  'gtk',
  'it',
  'j2b',
  'm15',
  'med',
  'mod',
  'mtm',
  'okt',
  'psm',
  'pt36',
  'ptm',
  's3m',
  'stm',
  'stp',
  'stx',
  'ult',
  'umx',
  'xm',
  'xmz',
  'itz',
  's3z',
};

bool isTrackerModulePath(String path) =>
    trackerModuleExtensions.contains(path.split('.').last.toLowerCase());

const midiFileExtensions = <String>{'mid', 'midi', 'kar'};

bool isMidiFilePath(String path) =>
    midiFileExtensions.contains(path.split('.').last.toLowerCase());

class TrackerModuleInfo {
  const TrackerModuleInfo({required this.title, required this.format});

  final String title;
  final String format;

  factory TrackerModuleInfo.fromMap(Map<Object?, Object?> values) =>
      TrackerModuleInfo(
        title: values['title'] as String? ?? '',
        format: values['format'] as String? ?? '',
      );
}

class TrackerModuleDecoder {
  static const _channel = MethodChannel('neonamp/tracker');

  static Future<TrackerModuleInfo> readInfo(String path) async {
    final values = await _channel.invokeMapMethod<Object?, Object?>(
      'readInfo',
      {'inputPath': path},
    );
    if (values == null) {
      throw const FormatException('Unsupported tracker module.');
    }
    return TrackerModuleInfo.fromMap(values);
  }

  static Future<void> decodeToWav(String inputPath, String outputPath) async {
    final decoded = await _channel.invokeMethod<bool>('decodeToWav', {
      'inputPath': inputPath,
      'outputPath': outputPath,
    });
    if (decoded != true) {
      throw const FormatException('Could not decode tracker module.');
    }
  }
}
