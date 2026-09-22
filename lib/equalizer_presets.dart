const Map<String, List<double>> builtInEqualizerPresets = {
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Rock': [4, 3, 1, -1, -1, 0, 2, 3, 4, 4],
  'Pop': [-1, 1, 3, 4, 2, -1, -1, 1, 2, 3],
  'Jazz': [3, 2, 1, 0, -1, -1, 0, 1, 2, 3],
  'Classical': [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
  'Bass boost': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'Acoustic': [3, 2, 0, 1, 3, 3, 2, 1, 0, 1],
  'Club': [-2, 1, 4, 3, 1, 0, 2, 3, 1, -1],
  'Dance': [4, 3, 1, 0, -1, -2, 0, 2, 4, 5],
  'Full Bass': [8, 6, 4, 2, 0, -1, -2, -2, -2, -2],
  'Full Bass & Treble': [6, 5, 3, 1, -1, -2, 0, 2, 4, 6],
  'Full Treble': [-2, -2, -2, -1, 0, 2, 4, 6, 7, 8],
  'Headphones': [2, 1, 0, -1, 0, 1, 2, 3, 2, 1],
  'Large Hall': [5, 4, 2, 0, -2, -2, 0, 2, 4, 5],
  'Live': [2, 1, -1, -2, -1, 1, 3, 3, 1, -1],
  'Party': [5, 3, 0, -2, -1, -1, 1, 3, 4, 4],
  'Reggae': [0, 1, 0, -2, 1, 3, 2, 0, -1, 0],
  'Ska': [2, 4, 3, 1, -1, -3, -2, 0, 2, 3],
  'Soft': [-2, 0, 2, 3, 2, 0, -1, -2, -3, -3],
  'Soft Rock': [2, 2, 1, 0, -2, -1, 1, 3, 4, 3],
  'Techno': [4, 3, 0, -2, -3, 0, 1, 4, 5, 5],
  'Vocal': [-4, -3, -1, 2, 4, 4, 3, 1, -1, -2],
};

Map<String, List<double>> decodeCustomEqualizerPresets(Object? value) {
  if (value is! Map) return {};
  final presets = <String, List<double>>{};
  for (final entry in value.entries) {
    final name = entry.key.toString().trim();
    final bands = entry.value;
    if (name.isEmpty || bands is! List || bands.length != 10) continue;
    if (builtInEqualizerPresets.keys.any(
      (builtIn) => builtIn.toLowerCase() == name.toLowerCase(),
    )) {
      continue;
    }
    if (bands.any((band) => band is! num || !band.isFinite)) continue;
    presets[name] = bands
        .cast<num>()
        .map((band) => band.toDouble().clamp(-12, 12).toDouble())
        .toList();
  }
  return presets;
}

bool canSaveEqualizerPresetName(
  String name, {
  Iterable<String> reservedNames = const [],
}) {
  final normalizedName = name.trim().toLowerCase();
  if (normalizedName.isEmpty) return false;
  return ![
    ...builtInEqualizerPresets.keys,
    ...reservedNames,
  ].any((reserved) => reserved.toLowerCase() == normalizedName);
}

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
