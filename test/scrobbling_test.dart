import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/scrobbling.dart';

void main() {
  test('serializes ListenBrainz now-playing payload', () {
    final payload = buildListenBrainzPayload(
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      durationSeconds: 240,
    );
    final decoded = jsonDecode(jsonEncode(payload));
    expect(decoded['listen_type'], 'playing_now');
    expect(decoded['payload']['track_metadata']['track_name'], 'Track');
    expect(decoded['payload']['track_metadata']['additional_info']['duration'], 240);
  });

  test('profile round-trips enabled state and token', () {
    const profile = ScrobbleProfile(token: 'abc', enabled: false);
    expect(ScrobbleProfile.fromJson(profile.toJson()).toJson(), profile.toJson());
  });
}
