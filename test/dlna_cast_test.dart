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

  group('CUE segment position mapping', () {
    const start = Duration(minutes: 1, seconds: 30);
    const end = Duration(minutes: 2, seconds: 15);

    test('converts renderer source time to a zero-based segment position', () {
      expect(
        DlnaCast.sourceToSegmentPosition(
          const Duration(minutes: 1, seconds: 45),
          start,
          end,
        ),
        const Duration(seconds: 15),
      );
      expect(
        DlnaCast.sourceToSegmentPosition(
          const Duration(minutes: 1),
          start,
          end,
        ),
        Duration.zero,
      );
      expect(
        DlnaCast.sourceToSegmentPosition(
          const Duration(minutes: 3),
          start,
          end,
        ),
        const Duration(seconds: 45),
      );
    });

    test('converts segment seeks to source time and clamps boundaries', () {
      expect(
        DlnaCast.segmentToSourcePosition(
          const Duration(seconds: 12),
          start,
          end,
        ),
        const Duration(minutes: 1, seconds: 42),
      );
      expect(
        DlnaCast.segmentToSourcePosition(
          const Duration(minutes: 1),
          start,
          end,
        ),
        end,
      );
      expect(
        DlnaCast.segmentToSourcePosition(
          const Duration(seconds: -5),
          start,
          end,
        ),
        start,
      );
    });
  });

  group('DLNA time parsing', () {
    test('parses hours and fractional seconds', () {
      expect(
        DlnaCast.parseDlnaPosition('01:02:03.45'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 450),
      );
    });

    test('rejects malformed and out-of-range clock components', () {
      expect(DlnaCast.parseDlnaPosition('00:60:00'), isNull);
      expect(DlnaCast.parseDlnaPosition('00:00:60'), isNull);
      expect(DlnaCast.parseDlnaPosition('not a time'), isNull);
    });
  });
}
