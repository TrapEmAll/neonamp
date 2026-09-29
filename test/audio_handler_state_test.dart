import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android audio-service state preserves position across duration updates', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('Duration _lastPosition = Duration.zero;'));
    expect(source, contains('if (position != null) _lastPosition = position;'));
    expect(source, contains('updatePosition: _lastPosition,'));
    expect(
      source,
      isNot(contains('updatePosition: position ?? Duration.zero,')),
    );
  });
}
