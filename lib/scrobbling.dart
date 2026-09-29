import 'dart:convert';
import 'dart:io';

class ScrobbleTrack {
  const ScrobbleTrack({
    required this.title,
    required this.artist,
    required this.album,
  });

  final String title;
  final String artist;
  final String album;
}

enum ScrobbleProtocol { listenBrainz, lastFmCompatible }

class ScrobbleClient {
  ScrobbleClient({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  Future<void> submit({
    required Uri endpoint,
    required String token,
    required ScrobbleProtocol protocol,
    required ScrobbleTrack track,
    required DateTime startedAt,
  }) async {
    if (token.trim().isEmpty) throw ArgumentError('A scrobbling token is required.');
    final request = await _client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    if (protocol == ScrobbleProtocol.listenBrainz) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Token ${token.trim()}');
      request.write(jsonEncode({
        'listen_type': 'single',
        'payload': [
          {
            'listened_at': startedAt.millisecondsSinceEpoch ~/ 1000,
            'track_metadata': {
              'track_name': track.title,
              'artist_name': track.artist,
              'release_name': track.album,
            },
          },
        ],
      }));
    } else {
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      request.write(Uri(queryParameters: {
        'method': 'track.scrobble',
        'artist': track.artist,
        'track': track.title,
        'album': track.album,
        'timestamp': '${startedAt.millisecondsSinceEpoch ~/ 1000}',
        'sk': token.trim(),
      }).query);
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Scrobble service returned ${response.statusCode}: $body', uri: endpoint);
    }
  }

  void close() => _client.close(force: true);
}
