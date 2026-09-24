import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/auto_eq.dart';

void main() {
  test('resamples frequency/gain JSON onto ten bands', () {
    final profile = parseAutoEqProfile(
      '{"name":"Example","frequency":[31,1000,16000],"equalization":[8,0,-8]}',
    );
    expect(profile.name, 'Example');
    expect(profile.gains, hasLength(10));
    expect(profile.gains.first, closeTo(8, 0.01));
    expect(profile.gains[5], closeTo(0, 0.01));
    expect(profile.gains.last, closeTo(-8, 0.01));
  });

  test('accepts CSV and clamps unsafe gains', () {
    final profile = parseAutoEqProfile(
      '31,20\n1000,0\n16000,-20',
      fallbackName: 'CSV',
    );
    expect(profile.gains.first, 12);
    expect(profile.gains.last, -12);
  });

  test('rejects unusable profiles', () {
    expect(() => parseAutoEqProfile('frequency,gain\nno,data'), throwsFormatException);
  });
}
