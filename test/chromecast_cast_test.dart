import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/chromecast_cast.dart';

void main() {
  group('audioContentType', () {
    test('maps common Chromecast audio formats to audio MIME types', () {
      expect(audioContentType('track.mp3'), 'audio/mpeg');
      expect(audioContentType('track.m4a'), 'audio/mp4');
      expect(audioContentType('track.aac'), 'audio/aac');
      expect(audioContentType('track.wav'), 'audio/wav');
      expect(audioContentType('track.ogg'), 'audio/ogg');
      expect(audioContentType('track.flac'), 'audio/flac');
    });

    test('is case-insensitive and rejects unverified formats', () {
      expect(audioContentType('track.MP3'), 'audio/mpeg');
      expect(audioContentType('track.wma'), isNull);
      expect(audioContentType('track.mid'), isNull);
    });
  });
}
