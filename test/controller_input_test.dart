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

  test('round-trips custom bindings and preserves defaults', () {
    final custom = Map<ControllerAction, int>.from(defaultControllerBindings)
      ..[ControllerAction.next] = 1234;
    final restored = controllerBindingsFromJson(controllerBindingsToJson(custom));
    expect(restored[ControllerAction.next], 1234);
    expect(restored[ControllerAction.playPause], 96);
    expect(
      controllerActionForKeyId(1234, bindings: restored),
      ControllerAction.next,
    );
  });

  test('ignores unrelated keys', () {
    expect(controllerActionForKeyId(65), isNull);
  });
}
