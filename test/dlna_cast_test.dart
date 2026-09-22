import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/dlna_cast.dart';

void main() {
  group('parseDlnaByteRange', () {
    test('returns the whole file when no range is requested', () {
      expect(DlnaCast.parseDlnaByteRange(null, 12), (0, 11, false));
    });

    test('handles bounded and open-ended byte ranges', () {
      expect(DlnaCast.parseDlnaByteRange('bytes=3-6', 12), (3, 6, true));
      expect(DlnaCast.parseDlnaByteRange('bytes=9-', 12), (9, 11, true));
    });

    test('handles suffix ranges and clamps the end to file length', () {
      expect(DlnaCast.parseDlnaByteRange('bytes=-4', 12), (8, 11, true));
      expect(DlnaCast.parseDlnaByteRange('bytes=8-99', 12), (8, 11, true));
    });

    test('rejects malformed, empty, and unsatisfiable ranges', () {
      expect(DlnaCast.parseDlnaByteRange('items=1-2', 12), isNull);
      expect(DlnaCast.parseDlnaByteRange('bytes=12-', 12), isNull);
      expect(DlnaCast.parseDlnaByteRange('bytes=9-2', 12), isNull);
      expect(DlnaCast.parseDlnaByteRange('bytes=-0', 12), isNull);
      expect(DlnaCast.parseDlnaByteRange(null, 0), isNull);
    });
  });
}
