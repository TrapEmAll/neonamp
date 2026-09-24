import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/silence_detection.dart';

void main() {
  test('parses leading and trailing silence from FFmpeg logs', () {
    final profile = parseSilenceDetect('''
[silencedetect] silence_start: 0
[silencedetect] silence_end: 1.250 | silence_duration: 1.250
[silencedetect] silence_start: 8.500
''', duration: const Duration(seconds: 10));
    expect(profile.leading, const Duration(milliseconds: 1250));
    expect(profile.trailing, const Duration(milliseconds: 1500));
  });

  test('does not mark a resumed silence as trailing', () {
    final profile = parseSilenceDetect('silence_start: 0\\nsilence_end: 1', duration: const Duration(seconds: 2));
    expect(profile.trailing, Duration.zero);
  });

  test('adjusts crossfade within safe bounds', () {
    final duration = adjustSilenceAwareCrossfade(
      base: const Duration(seconds: 3),
      outgoing: const SilenceProfile(trailing: Duration(seconds: 2)),
      incoming: const SilenceProfile(leading: Duration(seconds: 1)),
    );
    expect(duration, const Duration(seconds: 2));
  });
}
