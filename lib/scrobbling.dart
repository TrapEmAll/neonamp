import 'dart:convert';
import 'dart:io';

class ScrobbleProfile {
  const ScrobbleProfile({required this.token, this.enabled = true});
  final String token;
  final bool enabled;
  Map<String, dynamic> toJson() => {'token': token, 'enabled': enabled};
  factory ScrobbleProfile.fromJson(Map<String, dynamic> json) => ScrobbleProfile(
    token: json['token'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
  );
}

Map<String, dynamic> buildListenBrainzPayload({
  required String title,
  required String artist,
  required String album,
  int? durationSeconds,
}) => {
  'listen_type': 'playing_now',
  'payload': {
    'track_metadata': {
      'track_name': title,
      'artist_name': artist,
      'release_name': album,
      if (durationSeconds != null) 'additional_info': {'duration': durationSeconds},
    },
  },
};

class ListenBrainzScrobbler {
  ListenBrainzScrobbler(this.profile, {HttpClient? httpClient})
      : _httpClient = httpClient ?? HttpClient();
  final ScrobbleProfile profile;
  final HttpClient _httpClient;

  Future<bool> submitNowPlaying({
    required String title,
    required String artist,
    required String album,
    int? durationSeconds,
  }) async {
    if (!profile.enabled || profile.token.trim().isEmpty) return false;
    try {
      final request = await _httpClient.postUrl(
        Uri.parse('https://api.listenbrainz.org/1/submit-listens'),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Token ${profile.token.trim()}')
        ..contentType = ContentType.json;
      request.write(jsonEncode(buildListenBrainzPayload(
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
      )));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } on Object {
      return false;
    }
  }

  void close() => _httpClient.close(force: true);
}
