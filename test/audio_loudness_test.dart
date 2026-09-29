import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/audio_loudness.dart';

void main() {
  test('loudness gain moves measured LUFS toward the target', () {
    expect(gainDbToLoudnessTarget(-20), 6);
    expect(gainDbToLoudnessTarget(-10), -4);
    expect(gainDbToLoudnessTarget(double.nan), 0);
  });

  test('true peak gain never boosts an already-safe signal', () {
    expect(gainDbToTruePeakCeiling(-3), 0);
    expect(gainDbToTruePeakCeiling(0), -1);
    expect(gainDbToTruePeakCeiling(2, ceilingDb: -2), -4);
  });
}
