import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/loudness_scan.dart';

void main() {
  test('parses the final integrated LUFS value from ebur128 output', () {
    const output = '''
      [Parsed_ebur128_0 @ 0x1] I: -18.4 LUFS
      [Parsed_ebur128_0 @ 0x1] I: -16.2 LUFS
    ''';
    expect(parseEbur128IntegratedLufs(output), -16.2);
  });

  test('ignores invalid and non-integrated ebur128 lines', () {
    expect(
      parseEbur128IntegratedLufs(
        'M: -23.0 LUFS\nS: -20.0 LUFS\nI: not-ready LUFS',
      ),
      isNull,
    );
  });
}
