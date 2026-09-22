import 'package:xml/xml.dart';

class ItunesLibrary {
  const ItunesLibrary({required this.tracks, required this.playlists});

  final List<Map<String, Object?>> tracks;
  final Map<String, List<String>> playlists;
}

ItunesLibrary parseItunesLibrary(String source) {
  final document = XmlDocument.parse(source);
  final plist = document.rootElement;
  if (plist.name.local != 'plist' || plist.childElements.isEmpty) {
    throw const FormatException('This is not an iTunes library plist.');
  }
  final root = _readDictionary(plist.childElements.first);
  final rawTracks = root['Tracks'];
  if (rawTracks is! XmlElement || rawTracks.name.local != 'dict') {
    throw const FormatException('The iTunes library has no Tracks section.');
  }

  final tracksById = <String, Map<String, Object?>>{};
  for (final entry in _readDictionary(rawTracks).entries) {
    final node = entry.value;
    if (node is! XmlElement || node.name.local != 'dict') continue;
    final fields = _readDictionary(node);
    final location = _readString(fields['Location']);
    final path = _localPath(location);
    if (path == null) continue;
    tracksById[entry.key] = <String, Object?>{
      'path': path,
      'name': _readString(fields['Name']) ?? _lastPathPart(path),
      'artist': _readString(fields['Artist']) ?? 'Local library',
      'album': _readString(fields['Album']) ?? 'Unknown album',
      'genre': _readString(fields['Genre']) ?? 'Unknown genre',
      if (_readInteger(fields['Year']) case final int year) 'year': year,
      if (_readInteger(fields['Track Number']) case final int number)
        'trackNumber': number,
      if (_readInteger(fields['Track Count']) case final int total)
        'trackTotal': total,
      if (_readInteger(fields['Disc Number']) case final int number)
        'discNumber': number,
      if (_readInteger(fields['Disc Count']) case final int total)
        'discTotal': total,
    };
  }

  final rawPlaylists = root['Playlists'];
  final playlists = <String, List<String>>{};
  if (rawPlaylists is XmlElement && rawPlaylists.name.local == 'array') {
    for (final playlistNode in rawPlaylists.childElements.where(
      (element) => element.name.local == 'dict',
    )) {
      final fields = _readDictionary(playlistNode);
      final name = _readString(fields['Name'])?.trim();
      final items = fields['Playlist Items'];
      if (fields['Master'] is XmlElement &&
          (fields['Master']! as XmlElement).name.local == 'true') {
        continue;
      }
      if (name == null || name.isEmpty || items is! XmlElement) continue;
      final paths = <String>[];
      for (final item in items.childElements.where(
        (element) => element.name.local == 'dict',
      )) {
        final trackId = _readInteger(_readDictionary(item)['Track ID']);
        final path = trackId == null
            ? null
            : tracksById['$trackId']?['path'] as String?;
        if (path != null) paths.add(path);
      }
      if (paths.isNotEmpty) playlists[name] = paths;
    }
  }

  final uniqueTracks = <String, Map<String, Object?>>{};
  for (final track in tracksById.values) {
    uniqueTracks.putIfAbsent(track['path']! as String, () => track);
  }
  if (uniqueTracks.isEmpty && playlists.isEmpty) {
    throw const FormatException('No local tracks were found in this library.');
  }
  return ItunesLibrary(
    tracks: uniqueTracks.values.toList(),
    playlists: playlists,
  );
}

String buildItunesLibrary(
  Iterable<Map<String, Object?>> tracks,
  Map<String, List<String>> playlists,
) {
  final localTracks = <String, Map<String, Object?>>{};
  for (final track in tracks) {
    final path = track['path'];
    if (path is String && !path.startsWith('http')) {
      localTracks.putIfAbsent(path, () => track);
    }
  }
  final ids = <String, int>{};
  var nextId = 1;
  for (final path in localTracks.keys) {
    ids[path] = nextId++;
  }

  final builder = XmlBuilder();
  builder.processing('xml', 'version="1.0" encoding="UTF-8"');
  builder.element(
    'plist',
    attributes: {'version': '1.0'},
    nest: () {
      builder.element(
        'dict',
        nest: () {
          _writeKey(builder, 'Tracks');
          builder.element(
            'dict',
            nest: () {
              for (final entry in localTracks.entries) {
                final track = entry.value;
                builder.element('key', nest: ids[entry.key]!.toString());
                builder.element(
                  'dict',
                  nest: () {
                    _writeString(
                      builder,
                      'Name',
                      track['name'] as String? ?? '',
                    );
                    _writeString(
                      builder,
                      'Artist',
                      track['artist'] as String? ?? 'Local library',
                    );
                    _writeString(
                      builder,
                      'Album',
                      track['album'] as String? ?? 'Unknown album',
                    );
                    _writeString(
                      builder,
                      'Genre',
                      track['genre'] as String? ?? 'Unknown genre',
                    );
                    _writeInteger(builder, 'Track ID', ids[entry.key]!);
                    _writeInteger(
                      builder,
                      'Track Number',
                      track['trackNumber'],
                    );
                    _writeInteger(builder, 'Track Count', track['trackTotal']);
                    _writeInteger(builder, 'Disc Number', track['discNumber']);
                    _writeInteger(builder, 'Disc Count', track['discTotal']);
                    _writeInteger(builder, 'Year', track['year']);
                    builder.element('key', nest: 'Location');
                    builder.element(
                      'string',
                      nest: Uri.file(entry.key).toString(),
                    );
                    builder.element('key', nest: 'Track Type');
                    builder.element('string', nest: 'File');
                  },
                );
              }
            },
          );
          _writeKey(builder, 'Playlists');
          builder.element(
            'array',
            nest: () {
              builder.element(
                'dict',
                nest: () {
                  _writeString(builder, 'Name', 'Library');
                  builder.element('key', nest: 'Master');
                  builder.element('true');
                  builder.element('key', nest: 'Playlist Items');
                  builder.element(
                    'array',
                    nest: () {
                      for (final id in ids.values) {
                        builder.element(
                          'dict',
                          nest: () {
                            _writeInteger(builder, 'Track ID', id);
                          },
                        );
                      }
                    },
                  );
                },
              );
              for (final playlist in playlists.entries) {
                builder.element(
                  'dict',
                  nest: () {
                    _writeString(builder, 'Name', playlist.key);
                    builder.element('key', nest: 'Playlist Items');
                    builder.element(
                      'array',
                      nest: () {
                        for (final path in playlist.value) {
                          final id = ids[path];
                          if (id == null) continue;
                          builder.element(
                            'dict',
                            nest: () {
                              _writeInteger(builder, 'Track ID', id);
                            },
                          );
                        }
                      },
                    );
                  },
                );
              }
            },
          );
        },
      );
    },
  );
  return '${builder.buildDocument().toXmlString(pretty: true)}\n';
}

Map<String, XmlNode> _readDictionary(XmlElement element) {
  final children = element.childElements.toList();
  final result = <String, XmlNode>{};
  for (var index = 0; index + 1 < children.length; index += 2) {
    final key = children[index];
    if (key.name.local == 'key') result[key.innerText] = children[index + 1];
  }
  return result;
}

String? _readString(XmlNode? node) {
  if (node is! XmlElement || node.name.local != 'string') return null;
  return node.innerText;
}

int? _readInteger(XmlNode? node) {
  if (node is! XmlElement || node.name.local != 'integer') return null;
  return int.tryParse(node.innerText);
}

String? _localPath(String? location) {
  if (location == null) return null;
  final uri = Uri.tryParse(location);
  if (uri == null) return location;
  if (uri.scheme == 'file') {
    try {
      final host = uri.host.toLowerCase();
      if (host.isEmpty || host == 'localhost') {
        return uri
            .replace(host: '')
            .toFilePath(windows: RegExp(r'^/[A-Za-z]:/').hasMatch(uri.path));
      }
      return uri.toFilePath(windows: true);
    } on FormatException {
      return null;
    }
  }
  return uri.scheme.isEmpty ? location : null;
}

String _lastPathPart(String path) =>
    path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ??
    path;

void _writeKey(XmlBuilder builder, String value) =>
    builder.element('key', nest: value);

void _writeString(XmlBuilder builder, String key, String value) {
  _writeKey(builder, key);
  builder.element('string', nest: value);
}

void _writeInteger(XmlBuilder builder, String key, Object? value) {
  if (value is! num) return;
  _writeKey(builder, key);
  builder.element('integer', nest: value.toInt().toString());
}
