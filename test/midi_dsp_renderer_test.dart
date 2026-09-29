import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/midi_dsp_renderer.dart';

void main() {
  test('MIDI render duration includes release tail at 44.1 kHz', () {
    expect(
      midiRenderFrameCount(const Duration(seconds: 2)),
      3.8 * midiRenderSampleRate,
    );
  });

  test('MIDI renderer rejects empty and oversized sequences', () {
    expect(
      () => midiRenderFrameCount(Duration.zero),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => midiRenderFrameCount(const Duration(hours: 3)),
      throwsA(isA<FormatException>()),
    );
  });

  test('rendered audio uses a valid stereo PCM16 RIFF/WAVE header', () {
    final header = midiPcmWaveHeader(1600);
    final view = ByteData.sublistView(header);

    expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
    expect(view.getUint32(4, Endian.little), 1636);
    expect(String.fromCharCodes(header.sublist(8, 12)), 'WAVE');
    expect(view.getUint16(20, Endian.little), 1);
    expect(view.getUint16(22, Endian.little), 2);
    expect(view.getUint32(24, Endian.little), 44100);
    expect(view.getUint32(28, Endian.little), 176400);
    expect(view.getUint16(34, Endian.little), 16);
    expect(view.getUint32(40, Endian.little), 1600);
  });

  test('renderer rejects data sizes that cannot be represented in RIFF', () {
    expect(() => midiPcmWaveHeader(-4), throwsRangeError);
    expect(() => midiPcmWaveHeader(2), throwsRangeError);
    expect(() => midiPcmWaveHeader(0x100000000), throwsRangeError);
  });
}
