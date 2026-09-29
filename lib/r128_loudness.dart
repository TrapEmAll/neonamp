import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_loudness.dart';

/// A portable EBU R128 / ITU-R BS.1770 integrated-loudness measurement.
///
/// Samples are interleaved and normalized to the [-1, 1] PCM range. The
/// implementation uses the BS.1770 K-weighting filters, 400 ms blocks with a
/// 100 ms hop, and the absolute (-70 LUFS) and relative (-10 LU) gates.
class R128LoudnessAnalyzer {
  R128LoudnessAnalyzer({
    required this.sampleRate,
    required this.channelCount,
  })  : _blockFrames = (sampleRate * .4).round(),
        _hopFrames = (sampleRate * .1).round() {
    if (sampleRate < 1000) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
    if (channelCount < 1 || channelCount > 8) {
      throw ArgumentError.value(channelCount, 'channelCount');
    }
  }

  final int sampleRate;
  final int channelCount;
  final int _blockFrames;
  final int _hopFrames;

  /// Measures a complete interleaved PCM buffer.
  R128Measurement measure(Float64List samples) {
    if (samples.length < channelCount * _blockFrames) {
      return const R128Measurement.empty();
    }

    final filters = List.generate(
      channelCount,
      (_) => [_Biquad.kWeightingShelf(sampleRate), _Biquad.kWeightingHighPass(sampleRate)],
    );
    final filtered = List.generate(channelCount, (_) => <double>[]);
    for (var frame = 0; frame < samples.length ~/ channelCount; frame++) {
      for (var channel = 0; channel < channelCount; channel++) {
        var value = samples[frame * channelCount + channel];
        for (final filter in filters[channel]) {
          value = filter.process(value);
        }
        filtered[channel].add(value);
      }
    }

    final blockPowers = <double>[];
    final frameCount = samples.length ~/ channelCount;
    for (var end = _blockFrames; end <= frameCount; end += _hopFrames) {
      var energy = 0.0;
      final start = end - _blockFrames;
      for (var channel = 0; channel < channelCount; channel++) {
        var channelEnergy = 0.0;
        for (var frame = start; frame < end; frame++) {
          final value = filtered[channel][frame];
          channelEnergy += value * value;
        }
        energy += channelEnergy / _blockFrames;
      }
      blockPowers.add(energy / channelCount);
    }
    if (blockPowers.isEmpty) return const R128Measurement.empty();

    final absoluteGated = blockPowers.where((power) => _lufs(power) >= -70);
    final absolutePowers = absoluteGated.toList(growable: false);
    if (absolutePowers.isEmpty) return const R128Measurement.empty();

    final absoluteMean = _mean(absolutePowers);
    final relativeGate = _lufs(absoluteMean) - 10;
    final gatedPowers = absolutePowers
        .where((power) => _lufs(power) >= relativeGate)
        .toList(growable: false);
    if (gatedPowers.isEmpty) return const R128Measurement.empty();

    final peak = _truePeakEstimate(samples);
    return R128Measurement(
      integratedLufs: _lufs(_mean(gatedPowers)),
      truePeakDb: peak,
      gatedBlockCount: gatedPowers.length,
    );
  }

  static double _lufs(double meanSquare) =>
      meanSquare <= 0 ? double.negativeInfinity : -0.691 + 10 * math.log(meanSquare) / math.ln10;

  static double _mean(List<double> values) =>
      values.reduce((a, b) => a + b) / values.length;

  /// A conservative 4x linear-interpolation true-peak estimate.
  ///
  /// It is intentionally labelled an estimate: exact true-peak compliance
  /// requires the ITU-R BS.1770 oversampling filter, which can be added to the
  /// native decoder path without changing this API.
  static double _truePeakEstimate(Float64List samples) {
    var peak = 0.0;
    for (var index = 0; index < samples.length; index++) {
      final current = samples[index].abs();
      if (current > peak) peak = current;
      if (index + 1 < samples.length) {
        final next = samples[index + 1];
        for (var step = 1; step < 4; step++) {
          final interpolated = samples[index] + (next - samples[index]) * step / 4;
          peak = math.max(peak, interpolated.abs());
        }
      }
    }
    return peak <= 0 ? double.negativeInfinity : 20 * math.log(peak) / math.ln10;
  }
}

class R128Measurement {
  const R128Measurement({
    required this.integratedLufs,
    required this.truePeakDb,
    required this.gatedBlockCount,
  });

  const R128Measurement.empty()
      : integratedLufs = null,
        truePeakDb = null,
        gatedBlockCount = 0;

  final double? integratedLufs;
  final double? truePeakDb;
  final int gatedBlockCount;

  bool get hasSignal => integratedLufs != null;

  double gainToTarget([double targetLufs = defaultLoudnessTargetLufs]) {
    final measured = integratedLufs;
    if (measured == null) return 0;
    return gainDbToLoudnessTarget(measured, targetLufs: targetLufs);
  }
}

class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;
  double _x1 = 0;
  double _x2 = 0;
  double _y1 = 0;
  double _y2 = 0;

  double process(double input) {
    final output = b0 * input + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = input;
    _y2 = _y1;
    _y1 = output;
    return output;
  }

  factory _Biquad._fromNormalized(
    double b0,
    double b1,
    double b2,
    double a0,
    double a1,
    double a2,
  ) =>
      _Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);

  factory _Biquad.kWeightingShelf(int sampleRate) {
    const f0 = 1681.974450955533;
    const gainDb = 3.999843853973347;
    const q = .7071752369554196;
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * f0 / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final cos = math.cos(w0);
    final beta = 2 * math.sqrt(a) * alpha;
    return _Biquad._fromNormalized(
      a * ((a + 1) + (a - 1) * cos + beta),
      -2 * a * ((a - 1) + (a + 1) * cos),
      a * ((a + 1) + (a - 1) * cos - beta),
      (a + 1) - (a - 1) * cos + beta,
      2 * ((a - 1) - (a + 1) * cos),
      (a + 1) - (a - 1) * cos - beta,
    );
  }

  factory _Biquad.kWeightingHighPass(int sampleRate) {
    const f0 = 38.13547087602444;
    const q = .5003270373238773;
    final w0 = 2 * math.pi * f0 / sampleRate;
    final alpha = math.sin(w0) / (2 * q);
    final cos = math.cos(w0);
    return _Biquad._fromNormalized(
      (1 + cos) / 2,
      -(1 + cos),
      (1 + cos) / 2,
      1 + alpha,
      -2 * cos,
      1 - alpha,
    );
  }
}
