import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/controller_input.dart';

void main() {
  test('maps standard Android gamepad buttons to player actions', () {
    expect(controllerActionForKeyId(96), ControllerAction.playPause);
    expect(controllerActionForKeyId(97), ControllerAction.previous);
    expect(controllerActionForKeyId(99), ControllerAction.next);
    expect(controllerActionForKeyId(100), ControllerAction.mute);
    expect(controllerActionForKeyId(21), ControllerAction.seekBackward);
    expect(controllerActionForKeyId(22), ControllerAction.seekForward);
    expect(controllerActionForKeyId(108), ControllerAction.toggleOverlay);
  });

  test('ignores unrelated keys', () {
    expect(controllerActionForKeyId(65), isNull);
  });
}
