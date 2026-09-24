import 'dart:convert';
import 'dart:math' as math;

const autoEqCenterFrequencies = <double>[
  31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
];

class AutoEqProfile {
  const AutoEqProfile({
    required this.name,
    required this.gains,
    this.frequencies = autoEqCenterFrequencies,
  });
  final String name;
  final List<double> gains;
  final List<double> frequencies;
}

AutoEqProfile parseAutoEqProfile(String source, {String fallbackName = 'AutoEQ profile'}) {
  final text = source.trim();
  if (text.isEmpty) throw const FormatException('The AutoEQ profile is empty.');
  dynamic decoded;
  try { decoded = jsonDecode(text); } on FormatException {}
  if (decoded is Map) {
    final map = Map<String, dynamic>.from(decoded);
    final name = ['name', 'model_name', 'model', 'headphone']
        .map((key) => map[key]?.toString().trim())
        .firstWhere((value) => value != null && value.isNotEmpty, orElse: () => fallbackName)!;
    final frequency = _numbers(map['frequency'] ?? map['frequencies']);
    final gain = _numbers(map['equalization'] ?? map['gains'] ?? map['gain']);
    if (frequency != null && gain != null && frequency.length == gain.length) {
      return AutoEqProfile(
        name: name,
        gains: _resamplePoints([
          for (var i = 0; i < frequency.length; i++) [frequency[i], gain[i]]
        ]),
        frequencies: frequency.length == 10
            ? frequency.map((value) => value.clamp(20, 20000).toDouble()).toList()
            : autoEqCenterFrequencies,
      );
    }
    if (gain != null && gain.isNotEmpty) {
      return AutoEqProfile(name: name, gains: _resampleValues(gain));
    }
  }
  final points = <List<double>>[];
  for (final line in const LineSplitter().convert(text)) {
    final fields = line.split(RegExp(r'[,;\t]')).map((e) => e.trim()).toList();
    if (fields.length < 2) continue;
    final f = double.tryParse(fields[0]);
    final g = double.tryParse(fields[1]);
    if (f != null && g != null && f.isFinite && g.isFinite && f > 0) points.add([f, g]);
  }
  if (points.isEmpty) throw const FormatException('AutoEQ profile has no frequency/gain data.');
  return AutoEqProfile(
    name: fallbackName,
    gains: _resamplePoints(points),
    frequencies: points.length == 10
        ? points.map((point) => point[0].clamp(20, 20000).toDouble()).toList()
        : autoEqCenterFrequencies,
  );
}

List<double>? _numbers(Object? value) {
  if (value is! List) return null;
  final result = <double>[];
  for (final item in value) {
    final number = item is num ? item.toDouble() : double.tryParse(item.toString());
    if (number == null || !number.isFinite) return null;
    result.add(number);
  }
  return result;
}

List<double> _resampleValues(List<double> values) {
  if (values.length == 10) return values.map(_clamp).toList();
  return [
    for (var i = 0; i < 10; i++)
      _interpolate([
        for (var j = 0; j < values.length; j++) [j.toDouble(), values[j]]
      ], i * (values.length - 1) / 9)
  ];
}

List<double> _resamplePoints(List<List<double>> input) {
  final points = input.where((p) => p.length >= 2 && p[0] > 0).toList()
    ..sort((a, b) => a[0].compareTo(b[0]));
  if (points.isEmpty) throw const FormatException('AutoEQ profile has no valid frequencies.');
  return [
    for (final target in autoEqCenterFrequencies)
      _interpolate([
        for (final point in points) [math.log(point[0]), point[1]]
      ], math.log(target))
  ];
}

double _interpolate(List<List<double>> points, double target) {
  if (points.length == 1 || target <= points.first[0]) return _clamp(points.first[1]);
  if (target >= points.last[0]) return _clamp(points.last[1]);
  for (var i = 1; i < points.length; i++) {
    if (target <= points[i][0]) {
      final left = points[i - 1], right = points[i];
      final ratio = (target - left[0]) / (right[0] - left[0]);
      return _clamp(left[1] + (right[1] - left[1]) * ratio);
    }
  }
  return _clamp(points.last[1]);
}

double _clamp(double value) => value.clamp(-12, 12).toDouble();
