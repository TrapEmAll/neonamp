import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/audio_effects.dart';

void main() {
  test('validates and applies defaults for portable effects', () {
    final effect = PortableAudioEffect.fromJson({'type': 'echo'});
    expect(effect.value('delay'), .3);
    expect(effect.value('decay'), .7);
    expect(effect.toJson()['type'], 'echo');
  });

  test('rejects unknown effects and out-of-range parameters', () {
    expect(
      () => PortableAudioEffect.fromJson({'type': 'dll'}),
      throwsFormatException,
    );
    expect(
      () => PortableAudioEffect.fromJson({
        'type': 'bassBoost',
        'parameters': {'boost': 11},
      }),
      throwsFormatException,
    );
  });
}
