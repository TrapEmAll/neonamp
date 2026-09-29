import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/media_server.dart';

void main() {
  test('serializes server profiles without losing credentials', () {
    const profile = MediaServerProfile(
      kind: 'jellyfin',
      baseUrl: 'https://media.example/',
      username: 'alice',
      secret: 'token',
      userId: 'user-1',
    );
    expect(MediaServerProfile.fromJson(profile.toJson()).toJson(), profile.toJson());
  });

  test('builds a stable profile payload', () {
    const profile = MediaServerProfile(
      kind: 'subsonic',
      baseUrl: 'https://music.example',
      username: 'bob',
      secret: 'password',
    );
    expect(jsonDecode(jsonEncode(profile.toJson()))['kind'], 'subsonic');
  });
}
