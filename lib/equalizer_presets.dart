const Map<String, List<double>> builtInEqualizerPresets = {
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Rock': [4, 3, 1, -1, -1, 0, 2, 3, 4, 4],
  'Pop': [-1, 1, 3, 4, 2, -1, -1, 1, 2, 3],
  'Jazz': [3, 2, 1, 0, -1, -1, 0, 1, 2, 3],
  'Classical': [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
  'Bass boost': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
};

List<double> equalizerPresetBands(
  String preset, {
  Map<String, List<double>> pluginPresets = const {},
  int bandCount = 10,
}) {
  final values = pluginPresets[preset] ?? builtInEqualizerPresets[preset];
  return List<double>.generate(
    bandCount,
    (index) => values != null && index < values.length
        ? values[index].clamp(-12, 12).toDouble()
        : 0,
  );
}
