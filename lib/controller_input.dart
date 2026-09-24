enum ControllerAction {
  playPause,
  next,
  previous,
  seekForward,
  seekBackward,
  mute,
  toggleOverlay,
}

const defaultControllerBindings = <ControllerAction, int>{
  ControllerAction.playPause: 96,
  ControllerAction.next: 99,
  ControllerAction.previous: 97,
  ControllerAction.seekBackward: 21,
  ControllerAction.seekForward: 22,
  ControllerAction.mute: 100,
  ControllerAction.toggleOverlay: 108,
};

const controllerActionLabels = <ControllerAction, String>{
  ControllerAction.playPause: 'Play / pause',
  ControllerAction.next: 'Next track',
  ControllerAction.previous: 'Previous track',
  ControllerAction.seekBackward: 'Seek backward',
  ControllerAction.seekForward: 'Seek forward',
  ControllerAction.mute: 'Mute',
  ControllerAction.toggleOverlay: 'Toggle overlay',
};

ControllerAction? controllerActionForKeyId(
  int keyId, {
  Map<ControllerAction, int> bindings = defaultControllerBindings,
}) {
  for (final entry in bindings.entries) {
    if (entry.value == keyId) return entry.key;
  }
  return null;
}

Map<String, int> controllerBindingsToJson(
  Map<ControllerAction, int> bindings,
) => {
  for (final entry in bindings.entries) entry.key.name: entry.value,
};

Map<ControllerAction, int> controllerBindingsFromJson(Object? value) {
  final result = Map<ControllerAction, int>.from(defaultControllerBindings);
  if (value is! Map) return result;
  for (final action in ControllerAction.values) {
    final key = value[action.name];
    if (key is num && key.toInt() >= 0) result[action] = key.toInt();
  }
  return result;
}
