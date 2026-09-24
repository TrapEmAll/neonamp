import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/r128_loudness.dart';

void main() {
  test('R128 rejects silence and clips no signal', () {
    final analyzer = R128LoudnessAnalyzer(sampleRate: 48000, channelCount: 2);
    final result = analyzer.measure(Float64List(48000 * 2));
    expect(result.hasSignal, isFalse);
    expect(result.gainToTarget(), 0);
  });

  test('R128 applies K-weighting and gates a sustained tone', () {
    const sampleRate = 48000;
    const seconds = 1;
    final samples = Float64List(sampleRate * seconds * 2);
    for (var frame = 0; frame < sampleRate * seconds; frame++) {
      final value = .1 * (frame % 48 < 24 ? 1.0 : -1.0);
      samples[frame * 2] = value;
      samples[frame * 2 + 1] = value;
    }

    final result = R128LoudnessAnalyzer(
      sampleRate: sampleRate,
      channelCount: 2,
    ).measure(samples);

    expect(result.hasSignal, isTrue);
    expect(result.gatedBlockCount, greaterThan(0));
    expect(result.integratedLufs, inInclusiveRange(-25, -15));
    expect(result.truePeakDb, closeTo(-20, 0.1));
    expect(result.gainToTarget(), closeTo(5, 10));
  });

  test('R128 exposes a conservative true-peak ceiling adjustment', () {
    final result = R128Measurement(
      integratedLufs: -20,
      truePeakDb: -0.2,
      gatedBlockCount: 1,
    );
    expect(result.gainToTarget(-14), 6);
    expect(gainDbToTruePeakCeiling(result.truePeakDb!), -0.8);
  });
}
