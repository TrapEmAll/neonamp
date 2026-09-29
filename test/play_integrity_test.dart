import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/play_integrity.dart';

void main() {
  test('Play Integrity request bindings are stable SHA-256 hashes', () {
    expect(
      PlayIntegrityClient.requestHash('POST /protected-action {}'),
      '3ef07771d9edfc6fa7190d12da04459e332f80c267e92b92c22e685ee2d5f669',
    );
  });
}
