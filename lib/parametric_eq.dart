import 'auto_eq.dart';

bool hasCustomFrequencyLayout(List<double> frequencies) {
  if (frequencies.length != autoEqCenterFrequencies.length) return false;
  for (var i = 0; i < frequencies.length; i++) {
    if ((frequencies[i] - autoEqCenterFrequencies[i]).abs() > 0.01) return true;
  }
  return false;
}

String buildFfmpegParametricEqFilter({
  required List<double> frequencies,
  required List<double> gains,
}) {
  if (frequencies.length != gains.length || frequencies.isEmpty) {
    throw ArgumentError('EQ frequencies and gains must have equal non-zero lengths.');
  }
  final filters = <String>[];
  for (var i = 0; i < frequencies.length; i++) {
    final frequency = frequencies[i];
    final gain = gains[i];
    if (!frequency.isFinite || frequency < 20 || frequency > 20000 || !gain.isFinite) continue;
    final clampedGain = gain.clamp(-12.0, 12.0).toDouble();
    if (clampedGain.abs() < 0.001) continue;
    filters.add('equalizer=f=${_format(frequency)}:t=q:w=1:g=${_format(clampedGain)}');
  }
  return filters.isEmpty ? 'anull' : filters.join(',');
}

String _format(double value) => value.toStringAsFixed(3).replaceFirst(RegExp(r'\.0+$'), '');
