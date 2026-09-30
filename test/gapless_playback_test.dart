import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/gapless_playback.dart';

void main() {
  test('accepts local filesystem paths for gapless playback', () {
    expect(isGaplessLocalPath(r'C:\Music\one.flac'), isTrue);
    expect(canUseGaplessQueue(['/music/one.flac', '/music/two.flac']), isTrue);
  });

  test('rejects remote and provider-backed sources', () {
    expect(isGaplessLocalPath('https://example.test/track.mp3'), isFalse);
    expect(isGaplessLocalPath('content://media/external/audio/1'), isFalse);
    expect(isGaplessLocalPath('file:///music/track.flac'), isFalse);
    expect(
      canUseGaplessQueue(['/music/one.flac', 'https://example.test/two.mp3']),
      isFalse,
    );
  });
}
