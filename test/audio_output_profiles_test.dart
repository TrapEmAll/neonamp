import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/audio_output_profiles.dart';

void main() {
  test('normalizes output route keys for persisted device profiles', () {
    expect(
      audioOutputProfileKey(routeName: '  USB DAC ', routeType: 'TYPE_USB_DEVICE'),
      'type_usb_device|usb dac',
    );
    expect(audioOutputProfileKey(), 'default');
    expect(audioOutputProfileKey(routeType: 'TYPE_BLUETOOTH_A2DP'), 'type_bluetooth_a2dp|unnamed');
  });
}
