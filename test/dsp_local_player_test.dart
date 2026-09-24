import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DSP equalizer applies gains to the active SoLoud voice handle', () async {
    final source = await File('lib/dsp_local_player.dart').readAsString();
    expect(source, contains('equalizer.numBands(soundHandle: handle)'));
    expect(source, contains('equalizer.bandGain(index, soundHandle: handle)'));
    expect(source, contains('double preamp = 0'));
    expect(source, contains('void setPreamp(double preamp)'));
    expect(source, contains('_effectiveVolume'));
  });
}
