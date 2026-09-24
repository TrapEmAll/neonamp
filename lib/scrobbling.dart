import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class ScrobbleProfile {
  const ScrobbleProfile({
    this.token = '',
    this.enabled = true,
    this.lastFmApiKey = '',
    this.lastFmSessionKey = '',
    this.lastFmSharedSecret = '',
    this.libreFmApiKey = '',
    this.libreFmSessionKey = '',
    this.libreFmSharedSecret = '',
  });

  /// ListenBrainz user token. Kept as [token] for backwards compatibility.
  final String token;
  final bool enabled;
  final String lastFmApiKey;
  final String lastFmSessionKey;
  final String lastFmSharedSecret;
  final String libreFmApiKey;
  final String libreFmSessionKey;
  final String libreFmSharedSecret;

  Map<String, dynamic> toJson() => {
    'token': token,
    'enabled': enabled,
    'lastFmApiKey': lastFmApiKey,
    'lastFmSessionKey': lastFmSessionKey,
    'lastFmSharedSecret': lastFmSharedSecret,
    'libreFmApiKey': libreFmApiKey,
    'libreFmSessionKey': libreFmSessionKey,
    'libreFmSharedSecret': libreFmSharedSecret,
  };

  factory ScrobbleProfile.fromJson(Map<String, dynamic> json) => ScrobbleProfile(
    token: json['token'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    lastFmApiKey: json['lastFmApiKey'] as String? ?? '',
    lastFmSessionKey: json['lastFmSessionKey'] as String? ?? '',
    lastFmSharedSecret: json['lastFmSharedSecret'] as String? ?? '',
    libreFmApiKey: json['libreFmApiKey'] as String? ?? '',
    libreFmSessionKey: json['libreFmSessionKey'] as String? ?? '',
    libreFmSharedSecret: json['libreFmSharedSecret'] as String? ?? '',
  );
}

String buildLastFmApiSignature(
  Map<String, String> params,
  String sharedSecret,
) {
  final keys = params.keys.toList()..sort();
  return md5.convert(utf8.encode(
    '${keys.map((key) => '$key${params[key]}').join()}${sharedSecret.trim()}',
  )).toString();
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

  Future<bool> submitScrobble({
    required String title,
    required String artist,
    required String album,
    required int timestampSeconds,
    int? durationSeconds,
  }) async {
    if (!profile.enabled || profile.token.trim().isEmpty) return false;
    try {
      final request = await _httpClient.postUrl(Uri.parse('https://api.listenbrainz.org/1/submit-listens'));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Token ${profile.token.trim()}')
        ..contentType = ContentType.json;
      request.write(jsonEncode({
        'listen_type': 'single',
        'payload': [{
          'listened_at': timestampSeconds,
          'track_metadata': {
            'track_name': title,
            'artist_name': artist,
            'release_name': album,
            if (durationSeconds != null) 'additional_info': {'duration': durationSeconds},
          },
        }],
      }));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode >= 200 && response.statusCode < 300;
    } on Object {
      return false;
    }
  }

  void close() => _httpClient.close(force: true);
}

/// Last.fm-compatible account scrobbler. Libre.fm uses the same protocol.
class LastFmScrobbler {
  LastFmScrobbler({
    required this.apiKey,
    required this.sessionKey,
    required this.sharedSecret,
    this.endpoint = 'https://ws.audioscrobbler.com/2.0/',
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final String apiKey;
  final String sessionKey;
  final String sharedSecret;
  final String endpoint;
  final HttpClient _httpClient;

  Future<bool> submitNowPlaying({
    required String title,
    required String artist,
    required String album,
    int? durationSeconds,
  }) async {
    if (apiKey.trim().isEmpty || sessionKey.trim().isEmpty) return false;
    final params = <String, String>{
      'album': album,
      'api_key': apiKey.trim(),
      'artist': artist,
      if (durationSeconds != null && durationSeconds > 0)
        'duration': durationSeconds.toString(),
      'method': 'track.updateNowPlaying',
      'sk': sessionKey.trim(),
      'track': title,
    };
    return _submit(params);
  }

  Future<bool> _submit(Map<String, String> params) async {
    try {
      final signature = buildLastFmApiSignature(params, sharedSecret);
      if (signature.isEmpty) return false;
      final request = await _httpClient.postUrl(Uri.parse(endpoint));
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(Uri(queryParameters: {...params, 'api_sig': signature, 'format': 'json'}).query);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['error'] == null;
    } on Object {
      return false;
    }
  }

  Future<bool> submitScrobble({
    required String title,
    required String artist,
    required String album,
    required int timestampSeconds,
    int? durationSeconds,
  }) async {
    if (apiKey.trim().isEmpty || sessionKey.trim().isEmpty || sharedSecret.trim().isEmpty) return false;
    final params = <String, String>{
      'album': album,
      'api_key': apiKey.trim(),
      'artist': artist,
      if (durationSeconds != null && durationSeconds > 0) 'duration': durationSeconds.toString(),
      'method': 'track.scrobble',
      'sk': sessionKey.trim(),
      'timestamp': timestampSeconds.toString(),
      'track': title,
    };
    return _submit(params);
  }

  void close() => _httpClient.close(force: true);
}

class MultiServiceScrobbler {
  MultiServiceScrobbler(this.profile, {HttpClient? httpClient})
      : _httpClient = httpClient ?? HttpClient();

  final ScrobbleProfile profile;
  final HttpClient _httpClient;

  Future<void> submitNowPlaying({
    required String title,
    required String artist,
    required String album,
    int? durationSeconds,
  }) async {
    if (!profile.enabled) return;
    final clients = <Future<bool>>[];
    if (profile.token.trim().isNotEmpty) {
      clients.add(ListenBrainzScrobbler(profile, httpClient: _httpClient).submitNowPlaying(
        title: title, artist: artist, album: album, durationSeconds: durationSeconds,
      ));
    }
    if (profile.lastFmApiKey.trim().isNotEmpty && profile.lastFmSessionKey.trim().isNotEmpty && profile.lastFmSharedSecret.trim().isNotEmpty) {
      clients.add(LastFmScrobbler(
        apiKey: profile.lastFmApiKey,
        sessionKey: profile.lastFmSessionKey,
        sharedSecret: profile.lastFmSharedSecret,
        httpClient: _httpClient,
      ).submitNowPlaying(
        title: title, artist: artist, album: album, durationSeconds: durationSeconds,
      ));
    }
    if (profile.libreFmApiKey.trim().isNotEmpty && profile.libreFmSessionKey.trim().isNotEmpty && profile.libreFmSharedSecret.trim().isNotEmpty) {
      clients.add(LastFmScrobbler(
        apiKey: profile.libreFmApiKey,
        sessionKey: profile.libreFmSessionKey,
        sharedSecret: profile.libreFmSharedSecret,
        endpoint: 'https://turtle.libre.fm/2.0/',
        httpClient: _httpClient,
      ).submitNowPlaying(
        title: title, artist: artist, album: album, durationSeconds: durationSeconds,
      ));
    }
    if (clients.isNotEmpty) await Future.wait(clients);
  }

  Future<void> submitScrobble({
    required String title,
    required String artist,
    required String album,
    required int timestampSeconds,
    int? durationSeconds,
  }) async {
    if (!profile.enabled) return;
    final clients = <Future<bool>>[];
    if (profile.token.trim().isNotEmpty) {
      clients.add(ListenBrainzScrobbler(profile, httpClient: _httpClient).submitScrobble(
        title: title, artist: artist, album: album,
        timestampSeconds: timestampSeconds, durationSeconds: durationSeconds,
      ));
    }
    if (profile.lastFmApiKey.trim().isNotEmpty &&
        profile.lastFmSessionKey.trim().isNotEmpty &&
        profile.lastFmSharedSecret.trim().isNotEmpty) {
      clients.add(LastFmScrobbler(
        apiKey: profile.lastFmApiKey,
        sessionKey: profile.lastFmSessionKey,
        sharedSecret: profile.lastFmSharedSecret,
        httpClient: _httpClient,
      ).submitScrobble(
        title: title, artist: artist, album: album,
        timestampSeconds: timestampSeconds, durationSeconds: durationSeconds,
      ));
    }
    if (profile.libreFmApiKey.trim().isNotEmpty &&
        profile.libreFmSessionKey.trim().isNotEmpty &&
        profile.libreFmSharedSecret.trim().isNotEmpty) {
      clients.add(LastFmScrobbler(
        apiKey: profile.libreFmApiKey,
        sessionKey: profile.libreFmSessionKey,
        sharedSecret: profile.libreFmSharedSecret,
        endpoint: 'https://turtle.libre.fm/2.0/',
        httpClient: _httpClient,
      ).submitScrobble(
        title: title, artist: artist, album: album,
        timestampSeconds: timestampSeconds, durationSeconds: durationSeconds,
      ));
    }
    if (clients.isNotEmpty) await Future.wait(clients);
  }

  void close() => _httpClient.close(force: true);
}
