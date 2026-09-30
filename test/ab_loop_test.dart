import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/ab_loop.dart';

void main() {
  test('normalizes reversed A-B points', () {
    final loop = normalizedAbLoop(
      const Duration(seconds: 20),
      const Duration(seconds: 5),
    );
    expect(loop?.start, const Duration(seconds: 5));
    expect(loop?.end, const Duration(seconds: 20));
  });

  test('wraps only at the end of a valid enabled loop', () {
    expect(
      abLoopSeekTarget(
        enabled: true,
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 20),
        position: const Duration(seconds: 20),
      ),
      const Duration(seconds: 5),
    );
    expect(
      abLoopSeekTarget(
        enabled: false,
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 20),
        position: const Duration(seconds: 20),
      ),
      isNull,
    );
  });
}
