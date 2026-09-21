import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/main.dart';

void main() {
  test('smart playlist rules round-trip through JSON', () {
    const original = SmartPlaylist(
      name: 'Synthwave favorites',
      rule: 'Genre',
      value: 'Synthwave',
    );

    final restored = SmartPlaylist.fromJson(original.toJson());

    expect(restored.name, original.name);
    expect(restored.rule, original.rule);
    expect(restored.value, original.value);
  });

  testWidgets('renders the empty NeonAmp player', (tester) async {
    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();
    expect(find.text('NEONAMP'), findsOneWidget);
    expect(find.text('Your library is quiet.'), findsOneWidget);
  });
}
