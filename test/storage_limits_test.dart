import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/storage_limits.dart';

void main() {
  test('converts the cache slider value to native byte units', () {
    expect(
      libraryCacheBytesFromMegabytes(minimumLibraryCacheMegabytes),
      64 * 1024 * 1024,
    );
    expect(libraryCacheBytesFromMegabytes(512), 512 * 1024 * 1024);
  });
}
