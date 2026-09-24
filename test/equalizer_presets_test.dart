import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/equalizer_presets.dart';

void main() {
  test('built-in presets each provide a distinct 10-band curve', () {
    final curves = builtInEqualizerPresets.values
        .map((bands) => bands.join(','))
        .toSet();

    expect(curves, hasLength(builtInEqualizerPresets.length));
    expect(builtInEqualizerPresets.length, greaterThanOrEqualTo(20));
    for (final bands in builtInEqualizerPresets.values) {
      expect(bands, hasLength(10));
      expect(bands, everyElement(inInclusiveRange(-12, 12)));
    }
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

  test('saved custom frequency layouts require ordered audible frequencies', () {
    expect(
      decodeCustomEqualizerFrequencies({
        'Headphones': [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
        'Unordered': [31, 62, 125, 250, 500, 1000, 4000, 2000, 8000, 16000],
        'Out of range': [1, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
      }),
      {
        'Headphones': [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
      },
    );
  });

  test('custom preset names cannot shadow built-in or plugin presets', () {
    expect(canSaveEqualizerPresetName('  My curve  '), isTrue);
    expect(canSaveEqualizerPresetName(''), isFalse);
    expect(canSaveEqualizerPresetName('rOcK'), isFalse);
    expect(
      canSaveEqualizerPresetName('Studio', reservedNames: const ['Studio']),
      isFalse,
    );
  });

  test('saved custom preset data is validated and clamped when loaded', () {
    expect(
      decodeCustomEqualizerPresets({
        'My curve': [20, -20, 1, 2, 3, 4, 5, 6, 7, 8],
        'Rock': List<double>.filled(10, 3),
        'Short': [1, 2],
        'Not numeric': [1, 2, 3, 4, 5, 6, 7, 8, 9, 'bad'],
      }),
      {
        'My curve': [12, -12, 1, 2, 3, 4, 5, 6, 7, 8],
      },
    );
  });
}
