import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/artwork_transform.dart';

void main() {
  test('centers the square crop on a landscape image', () {
    expect(
      centeredArtworkCropRect(1600, 900),
      const ui.Rect.fromLTWH(350, 0, 900, 900),
    );
  });

  test('centers the square crop on a portrait image', () {
    expect(
      centeredArtworkCropRect(900, 1600),
      const ui.Rect.fromLTWH(0, 350, 900, 900),
    );
  });

  test('rejects unsafe output dimensions', () async {
    await expectLater(
      transformArtwork(
        Uint8List.fromList([1, 2, 3]),
        options: const ArtworkTransformOptions(
          maxDimension: 32,
          cropToSquare: true,
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
