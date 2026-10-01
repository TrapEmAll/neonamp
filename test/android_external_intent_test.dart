import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/android_external_intent.dart';

void main() {
  test('normalizes and deduplicates Android share payloads', () {
    final intents = deduplicateAndroidExternalIntents([
      const AndroidExternalIntent(path: ' content://media/1 ', name: ' Track '),
      const AndroidExternalIntent(path: 'content://media/1', name: 'Duplicate'),
      const AndroidExternalIntent(path: 'https://example.com/stream.mp3'),
      const AndroidExternalIntent(path: '  '),
    ]);

    expect(intents.map((item) => item.path), [
      'content://media/1',
      'https://example.com/stream.mp3',
    ]);
    expect(intents.first.name, 'Track');
    expect(intents.last.isRemoteUrl, isTrue);
  });
}
