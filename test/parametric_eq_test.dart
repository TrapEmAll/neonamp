import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/auto_eq.dart';
import 'package:neonamp/parametric_eq.dart';

void main() {
  test('detects custom center frequencies', () {
    expect(hasCustomFrequencyLayout(autoEqCenterFrequencies), isFalse);
    expect(hasCustomFrequencyLayout([20, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800]), isTrue);
  });

  test('builds an FFmpeg parametric filter chain', () {
    final filter = buildFfmpegParametricEqFilter(frequencies: [20, 1000, 20000], gains: [3, 0, -4]);
    expect(filter, 'equalizer=f=20:t=q:w=1:g=3,equalizer=f=20000:t=q:w=1:g=-4');
  });

  test('clamps unsafe gains and ignores invalid frequencies', () {
    final filter = buildFfmpegParametricEqFilter(frequencies: [10, 1000, 30000], gains: [20, -20, 4]);
    expect(filter, 'equalizer=f=1000:t=q:w=1:g=-12');
  });
  test('builds a custom Q value', () {
    final filter = buildFfmpegParametricEqFilter(
      frequencies: [1000],
      gains: [3],
      q: 1.75,
    );
    expect(filter, 'equalizer=f=1000:t=q:w=1.750:g=3');
  });

  test('parametric Q is validated', () {
    expect(
      () => buildFfmpegParametricEqFilter(
        frequencies: [1000],
        gains: [3],
        q: 0.05,
      ),
      throwsArgumentError,
    );
  });
}
