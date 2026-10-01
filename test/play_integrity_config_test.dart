import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/play_integrity_config.dart';

void main() {
  test('Play Integrity is disabled when no project number is compiled in', () {
    expect(PlayIntegrityConfig.cloudProjectNumber, isNull);
    expect(PlayIntegrityConfig.isConfigured, isFalse);
  });
}

