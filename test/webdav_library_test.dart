import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/webdav_library.dart';

void main() {
  test('recognizes supported WebDAV audio files without matching folders', () {
    expect(isWebDavAudioPath('https://nas.example/music/Live.FLAC'), isTrue);
    expect(isWebDavAudioPath('https://nas.example/music/cover.jpg'), isFalse);
    expect(isWebDavAudioPath('https://nas.example/music/disc.one'), isFalse);
  });

  test('serializes WebDAV profiles and keeps credentials out of plain track URLs', () {
    const profile = WebDavProfile(
      id: 'nas-1',
      name: 'NAS',
      baseUrl: 'https://nas.example/music/',
      username: 'alice@example.com',
      password: 'p@ss word',
    );
    final restored = WebDavProfile.fromJson(profile.toJson());
    expect(restored.id, profile.id);
    expect(restored.baseUrl, profile.baseUrl);
    final authenticated = webDavAuthenticatedUri(
      Uri.parse('https://nas.example/music/track.flac'),
      profile,
    );
    expect(authenticated.path, '/music/track.flac');
    expect(authenticated.toString(), contains('alice%40example.com'));
    expect(authenticated.toString(), contains('p%40ss%20word'));
  });
}
