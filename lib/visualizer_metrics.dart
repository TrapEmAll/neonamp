import 'dart:math' as math;

/// Stateful peak tracker for FFT visualizations.
///
/// Values are expected to be normalized amplitudes. Peaks decay gradually so
/// transient material remains visible between visualization frames.
class SpectrumPeakHold {
  SpectrumPeakHold({this.decay = 0.92});

  final double decay;
  List<double> _peaks = const [];

  List<double> update(Iterable<double> values) {
    final current = values.map((value) => value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0).toList(growable: false);
    if (_peaks.length != current.length) {
      _peaks = List<double>.from(current);
      return List<double>.from(_peaks);
    }
    _peaks = List<double>.generate(
      current.length,
      (index) => math.max(current[index], _peaks[index] * decay),
      growable: false,
    );
    return List<double>.from(_peaks);
  }

  void reset() => _peaks = const [];
}

double visualizerRms(Iterable<double> samples) {
  var sum = 0.0;
  var count = 0;
  for (final sample in samples) {
    if (!sample.isFinite) continue;
    sum += sample * sample;
    count++;
  }
  return count == 0 ? 0 : math.sqrt(sum / count).clamp(0.0, 1.0).toDouble();
}

double visualizerPeak(Iterable<double> samples) {
  var peak = 0.0;
  for (final sample in samples) {
    if (sample.isFinite) peak = math.max(peak, sample.abs());
  }
  return peak.clamp(0.0, 1.0).toDouble();
}
