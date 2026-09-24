import 'dart:convert';
import 'dart:io';

class MediaServerProfile {
  const MediaServerProfile({
    required this.kind,
    required this.baseUrl,
    required this.username,
    required this.secret,
    this.userId,
  });

  final String kind;
  final String baseUrl;
  final String username;
  final String secret;
  final String? userId;

  bool get isSubsonic => kind == 'subsonic';
  bool get isJellyfin => kind == 'jellyfin';

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'baseUrl': baseUrl,
    'username': username,
    'secret': secret,
    if (userId != null) 'userId': userId,
  };

  factory MediaServerProfile.fromJson(Map<String, dynamic> json) => MediaServerProfile(
    kind: json['kind'] as String? ?? 'subsonic',
    baseUrl: json['baseUrl'] as String? ?? '',
    username: json['username'] as String? ?? '',
    secret: json['secret'] as String? ?? '',
    userId: json['userId'] as String?,
  );
}

class MediaServerTrack {
  const MediaServerTrack({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    required this.streamUrl,
    this.year,
    this.durationMs,
  });

  final String id;
  final String name;
  final String artist;
  final String album;
  final String streamUrl;
  final int? year;
  final int? durationMs;
}

class MediaServerClient {
  MediaServerClient(this.profile, {HttpClient? httpClient}) : _httpClient = httpClient ?? HttpClient();

  final MediaServerProfile profile;
  final HttpClient _httpClient;

  Future<List<MediaServerTrack>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    if (profile.isSubsonic) return _searchSubsonic(query.trim());
    if (profile.isJellyfin) return _searchJellyfin(query.trim());
    throw ArgumentError.value(profile.kind, 'kind', 'Unsupported media server');
  }

  Future<List<MediaServerTrack>> _searchSubsonic(String query) async {
    final payload = await _getJson(_subsonicUri('search3', {
      'query': query,
      'songCount': '50',
      'songOffset': '0',
    }));
    final songs = (((payload['subsonic-response'] as Map?)?['searchResult3'] as Map?)?['song'] as List?) ?? const [];
    return [
      for (final raw in songs)
        if (raw is Map && raw['id'] != null)
          MediaServerTrack(
            id: raw['id'].toString(),
            name: raw['title']?.toString() ?? 'Untitled',
            artist: raw['artist']?.toString() ?? 'Unknown artist',
            album: raw['album']?.toString() ?? 'Unknown album',
            year: (raw['year'] as num?)?.toInt(),
            durationMs: (raw['duration'] as num?)?.toInt() == null
                ? null
                : (raw['duration'] as num).toInt() * 1000,
            streamUrl: _subsonicUri('stream', {'id': raw['id'].toString()}).toString(),
          ),
    ];
  }

  Future<List<MediaServerTrack>> _searchJellyfin(String query) async {
    final userId = profile.userId;
    if (userId == null || userId.isEmpty) {
      throw const FormatException('Jellyfin requires a user ID.');
    }
    final uri = _baseUri.replace(
      path: '${_baseUri.path}/Users/$userId/Items',
      queryParameters: {
        'searchTerm': query,
        'IncludeItemTypes': 'Audio',
        'Recursive': 'true',
        'Limit': '50',
        'Fields': 'Path,MediaSources,ProviderIds',
      },
    );
    final payload = await _getJson(uri);
    final items = (payload['Items'] as List?) ?? const [];
    return [
      for (final raw in items)
        if (raw is Map && raw['Id'] != null)
          MediaServerTrack(
            id: raw['Id'].toString(),
            name: raw['Name']?.toString() ?? 'Untitled',
            artist: _jellyfinArtist(raw),
            album: raw['Album']?.toString() ?? 'Unknown album',
            year: (raw['ProductionYear'] as num?)?.toInt(),
            durationMs: _jellyfinDurationMs(raw['RunTimeTicks']),
            streamUrl: _jellyfinStreamUrl(raw['Id'].toString(), userId).toString(),
          ),
    ];
  }

  Uri get _baseUri => Uri.parse(profile.baseUrl.endsWith('/') ? profile.baseUrl : '${profile.baseUrl}/');

  Uri _subsonicUri(String endpoint, Map<String, String> extra) {
    final query = <String, String>{
      'u': profile.username,
      'p': profile.secret,
      'v': '1.16.1',
      'c': 'NeonAmp',
      'f': 'json',
      ...extra,
    };
    return _baseUri.replace(path: '${_baseUri.path}rest/$endpoint.view', queryParameters: query);
  }

  Uri _jellyfinStreamUrl(String id, String userId) => _baseUri.replace(
    path: '${_baseUri.path}Audio/$id/universal',
    queryParameters: {
      'api_key': profile.secret,
      'UserId': userId,
      'Container': 'mp3,aac,m4a,flac,ogg,wav',
      'TranscodingContainer': 'mp3',
    },
  );

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (profile.isJellyfin) {
      request.headers.set(
        'Authorization',
        'MediaBrowser Client="NeonAmp", Device="Desktop", DeviceId="neonamp", Version="1.0", Token="${profile.secret}"',
      );
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Media server returned HTTP ${response.statusCode}', uri: uri);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('Media server returned invalid JSON.');
    return Map<String, dynamic>.from(decoded);
  }

  void close() => _httpClient.close(force: true);
}

String _jellyfinArtist(Map raw) {
  final albumArtists = raw['AlbumArtists'];
  if (albumArtists is List && albumArtists.isNotEmpty) {
    final first = albumArtists.first;
    if (first is Map && first['Name'] != null) return first['Name'].toString();
  }
  final artistItems = raw['ArtistItems'];
  if (artistItems is List && artistItems.isNotEmpty) {
    final first = artistItems.first;
    if (first is Map && first['Name'] != null) return first['Name'].toString();
  }
  return 'Unknown artist';
}

int? _jellyfinDurationMs(Object? ticks) {
  if (ticks is! num) return null;
  return (ticks / 10000).round();
}
