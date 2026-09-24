enum ControllerAction {
  playPause,
  next,
  previous,
  seekForward,
  seekBackward,
  mute,
  toggleOverlay,
}

/// Android USB/Bluetooth gamepad key codes. Flutter forwards these key events
/// to the focused player surface on Android and Windows-compatible controllers.
ControllerAction? controllerActionForKeyId(int keyId) {
  switch (keyId) {
    case 96: // A / DPAD center
    case 23:
      return ControllerAction.playPause;
    case 97: // B
      return ControllerAction.previous;
    case 99: // X
      return ControllerAction.next;
    case 100: // Y
      return ControllerAction.mute;
    case 21: // DPAD left
      return ControllerAction.seekBackward;
    case 22: // DPAD right
      return ControllerAction.seekForward;
    case 108: // START
      return ControllerAction.toggleOverlay;
    default:
      return null;
  }
}
