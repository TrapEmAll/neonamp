import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/scrobbling.dart';

void main() {
  test('builds the canonical Last.fm API signature', () {
    expect(
      lastFmApiSignature(
        {
          'track': 'Example Track',
          'artist': 'Example Artist',
          'album': 'Example Album',
          'timestamp': '1700000000',
          'method': 'track.scrobble',
          'api_key': 'key123',
          'sk': 'session123',
          'format': 'json',
        },
        'secret123',
      ),
      'b66919ad74ab8bf67d86c8c3e9849af4',
    );
  });
}
