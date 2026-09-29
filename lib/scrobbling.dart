import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

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

String lastFmApiSignature(
  Map<String, String> parameters,
  String apiSecret,
) {
  final canonical = (parameters.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)))
      .map((entry) => '${entry.key}${entry.value}')
      .join();
  return md5.convert(utf8.encode('$canonical${apiSecret.trim()}')).toString();
}

class ScrobbleClient {
  ScrobbleClient({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  Future<void> submit({
    required Uri endpoint,
    required String token,
    required ScrobbleProtocol protocol,
    required ScrobbleTrack track,
    required DateTime startedAt,
    String apiKey = '',
    String apiSecret = '',
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
      if (apiKey.trim().isEmpty || apiSecret.trim().isEmpty) {
        throw ArgumentError(
          'Last.fm-compatible services require an API key and secret.',
        );
      }
      final parameters = <String, String>{
        'album': track.album,
        'api_key': apiKey.trim(),
        'artist': track.artist,
        'format': 'json',
        'method': 'track.scrobble',
        'sk': token.trim(),
        'timestamp': '${startedAt.millisecondsSinceEpoch ~/ 1000}',
        'track': track.title,
      };
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      parameters['api_sig'] = lastFmApiSignature(parameters, apiSecret);
      request.write(Uri(queryParameters: parameters).query);
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Scrobble service returned ${response.statusCode}: $body', uri: endpoint);
    }
    if (protocol == ScrobbleProtocol.lastFmCompatible) {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] != null) {
        throw HttpException('Scrobble service rejected the listen: ${decoded['message'] ?? decoded['error']}', uri: endpoint);
      }
    }
  }

  void close() => _client.close(force: true);
}
