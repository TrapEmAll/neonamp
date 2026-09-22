const defaultPlayerControls = <String>[
  'rewind15',
  'previous',
  'shuffle',
  'playPause',
  'repeat',
  'forward15',
  'next',
];

const playerControlLabels = <String, String>{
  'previous': 'Previous track',
  'rewind15': 'Rewind 15 seconds',
  'playPause': 'Play / pause',
  'forward15': 'Skip forward 15 seconds',
  'next': 'Next track',
  'shuffle': 'Shuffle',
  'repeat': 'Repeat mode',
  'equalizer': 'Equalizer',
  'speed': 'Playback speed',
  'sleep': 'Sleep timer',
  'queue': 'Listening queue',
};

List<String> normalizePlayerControls(Object? value) {
  if (value is! List) return List<String>.from(defaultPlayerControls);
  final controls = <String>[];
  for (final item in value) {
    if (item is String &&
        playerControlLabels.containsKey(item) &&
        !controls.contains(item)) {
      controls.add(item);
    }
  }
  if (controls.isEmpty) return List<String>.from(defaultPlayerControls);
  if (!controls.contains('playPause')) {
    controls.insert(controls.length ~/ 2, 'playPause');
  }
  return controls;
}
