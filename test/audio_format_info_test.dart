import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/audio_format_info.dart';

void main() {
  test('parses WAV PCM format details', () {
    final bytes = Uint8List(47)
      ..setRange(0, 4, [0x52, 0x49, 0x46, 0x46])
      ..setRange(8, 12, [0x57, 0x41, 0x56, 0x45])
      ..setRange(12, 16, [0x66, 0x6d, 0x74, 0x20]);
    final data = ByteData.sublistView(bytes);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 2, Endian.little);
    data.setUint32(24, 48000, Endian.little);
    data.setUint16(34, 24, Endian.little);
    bytes.setRange(36, 40, [0x64, 0x61, 0x74, 0x61]);
    data.setUint32(40, 3, Endian.little);
    bytes.setRange(44, 47, [0xff, 0xff, 0x7f]);
    final info = parseAudioFormat(bytes)!;
    expect(info.codec, 'WAV');
    expect(info.sampleRate, 48000);
    expect(info.bitDepth, 24);
    expect(info.channels, 2);
    expect(info.peakDb, greaterThan(-0.1));
    expect(info.summary, contains('stereo'));
  });

  test('parses FLAC streaminfo details', () {
    final bytes = Uint8List(42)
      ..setRange(0, 4, [0x66, 0x4c, 0x61, 0x43]);
    final streamInfo = ByteData.sublistView(bytes, 18, 26);
    final packed = (96000 << 44) | (5 << 41) | (23 << 36);
    streamInfo.setUint64(0, packed, Endian.big);
    final info = parseAudioFormat(bytes)!;
    expect(info.codec, 'FLAC');
    expect(info.sampleRate, 96000);
    expect(info.channels, 6);
    expect(info.bitDepth, 24);
  });

  test('identifies DSD containers without inventing PCM details', () {
    final info = parseAudioFormat(
      Uint8List(4),
      path: 'album.dsf',
    )!;
    expect(info.codec, 'DSD');
    expect(info.sampleRate, isNull);
    expect(info.bitDepth, isNull);
  });

  test('returns null for unknown formats', () {
    expect(parseAudioFormat(Uint8List.fromList([1, 2, 3]), path: 'x.bin'), isNull);
  });
}
