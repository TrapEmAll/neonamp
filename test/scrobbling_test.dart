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

  test('Last.fm signatures are deterministic and sorted', () {
    final signature = buildLastFmApiSignature(
      {'track': 'Track', 'api_key': 'key', 'method': 'track.updateNowPlaying'},
      'secret',
    );
    expect(signature, hasLength(32));
    expect(
      signature,
      buildLastFmApiSignature(
        {'method': 'track.updateNowPlaying', 'api_key': 'key', 'track': 'Track'},
        'secret',
      ),
    );
  });

  test('profile round-trips all service credentials', () {
    const profile = ScrobbleProfile(
      token: 'abc',
      enabled: false,
      lastFmApiKey: 'lfm-key',
      lastFmSessionKey: 'lfm-session',
      lastFmSharedSecret: 'lfm-secret',
      libreFmApiKey: 'libre-key',
      libreFmSessionKey: 'libre-session',
      libreFmSharedSecret: 'libre-secret',
    );
    expect(ScrobbleProfile.fromJson(profile.toJson()).toJson(), profile.toJson());
  });
}
