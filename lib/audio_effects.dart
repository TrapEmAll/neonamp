const portableAudioEffectTypes = {'bassBoost', 'echo', 'reverb'};

class PortableAudioEffect {
  const PortableAudioEffect({required this.type, required this.parameters});

  factory PortableAudioEffect.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] as String?)?.trim() ?? '';
    if (!portableAudioEffectTypes.contains(type)) {
      throw FormatException('Unsupported audio effect: $type');
    }
    final definitions = _effectDefinitions[type]!;
    final rawParameters = json['parameters'];
    final parameters = <String, double>{};
    for (final entry in definitions.entries) {
      final rawValue = rawParameters is Map
          ? rawParameters[entry.key]
          : null;
      final value = rawValue is num ? rawValue.toDouble() : entry.value.$3;
      if (!value.isFinite || value < entry.value.$1 || value > entry.value.$2) {
        throw FormatException('Invalid $type parameter: ${entry.key}');
      }
      parameters[entry.key] = value;
    }
    return PortableAudioEffect(
      type: type,
      parameters: Map.unmodifiable(parameters),
    );
  }

  final String type;
  final Map<String, double> parameters;

  Map<String, dynamic> toJson() => {
    'type': type,
    'parameters': parameters,
  };

  double value(String name) => parameters[name] ?? 0;
}

// Parameter ranges are deliberately small and explicit so imported plugins
// cannot request unstable native filter values.
const Map<String, Map<String, (double, double, double)>> _effectDefinitions = {
  'bassBoost': {
    'wet': (0, 1, 1),
    'boost': (0, 10, 2),
  },
  'echo': {
    'wet': (0, 1, 1),
    'delay': (0.001, 3, 0.3),
    'decay': (0.001, 1, 0.7),
    'filter': (0, 1, 0),
  },
  'reverb': {
    'wet': (0, 1, 1),
    'freeze': (0, 1, 0),
    'roomSize': (0, 1, 0.5),
    'damp': (0, 1, 0.5),
    'width': (0, 1, 1),
  },
};

