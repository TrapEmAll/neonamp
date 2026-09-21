import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:neonamp/main.dart';

void main() {
  test('smart playlist rules round-trip through JSON', () {
    const original = SmartPlaylist(
      name: 'Synthwave favorites',
      rule: 'Genre',
      value: 'Synthwave',
      sortBy: 'Play count',
      descending: true,
      limit: 25,
    );

    final restored = SmartPlaylist.fromJson(original.toJson());

    expect(restored.name, original.name);
    expect(restored.rule, original.rule);
    expect(restored.value, original.value);
    expect(restored.sortBy, original.sortBy);
    expect(restored.descending, original.descending);
    expect(restored.limit, original.limit);
  });

  test('skin packages round-trip through JSON', () {
    const original = ThemeSkin(
      name: 'Midnight Citrus',
      seedColor: Color(0xffb7ff4a),
      backgroundColor: Color(0xff10130b),
    );

    final restored = ThemeSkin.fromJson(original.toJson());

    expect(restored.name, original.name);
    expect(restored.seedColor, original.seedColor);
    expect(restored.backgroundColor, original.backgroundColor);
  });

  test('skin packages reject malformed colors', () {
    expect(
      () => ThemeSkin.fromJson({
        'name': 'Broken',
        'seedColor': 'blue',
        'backgroundColor': '#101010',
      }),
      throwsFormatException,
    );
  });

  testWidgets('renders the empty NeonAmp player', (tester) async {
    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();
    expect(find.text('NEONAMP'), findsOneWidget);
    expect(find.text('Your library is quiet.'), findsOneWidget);
  });
}
