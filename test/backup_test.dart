import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/backup.dart';

void main() {
  test('round-trips a versioned backup payload', () {
    final restored = decodeNeonAmpBackup(
      encodeNeonAmpBackup({'queue': ['song.mp3'], 'volume': 0.8}),
    );
    expect(restored['queue'], ['song.mp3']);
    expect(restored['volume'], 0.8);
  });

  test('rejects unknown backup formats', () {
    expect(
      () => decodeNeonAmpBackup('{"format":"other","version":1,"state":{}}'),
      throwsFormatException,
    );
  });
}
