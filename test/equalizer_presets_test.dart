import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/equalizer_presets.dart';

void main() {
  test('built-in presets each provide a distinct 10-band curve', () {
    final curves = builtInEqualizerPresets.values
        .map((bands) => bands.join(','))
        .toSet();

    expect(curves, hasLength(builtInEqualizerPresets.length));
    for (final bands in builtInEqualizerPresets.values) {
      expect(bands, hasLength(10));
      expect(bands, everyElement(inInclusiveRange(-12, 12)));
    }
  });

  test('plugin names do not duplicate built-in preset names', () {
    expect(
      equalizerPresetNames(
        pluginPresets: const {
          'Rock': [1, 2, 3],
          'Podcast': [2, 1],
        },
      ),
      containsAllInOrder([
        ...builtInEqualizerPresets.keys,
        'Podcast',
      ]),
    );
    expect(
      equalizerPresetNames(
        pluginPresets: const {'Rock': [1, 2, 3]},
      ).where((name) => name == 'Rock'),
      hasLength(1),
    );
  });

  test('short plugin presets safely fill missing equalizer bands', () {
    expect(
      equalizerPresetBands(
        'Plugin preset',
        pluginPresets: const {
          'Plugin preset': [2, -3],
        },
      ),
      [2, -3, 0, 0, 0, 0, 0, 0, 0, 0],
    );
  });

  test('preset curves are clamped to the UI-supported gain range', () {
    expect(
      equalizerPresetBands(
        'Plugin preset',
        pluginPresets: const {
          'Plugin preset': [20, -20],
        },
        bandCount: 2,
      ),
      [12, -12],
    );
  });
}
