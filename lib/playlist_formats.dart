import 'dart:io';

import 'package:xml/xml.dart';

class PlaylistEntry {
  const PlaylistEntry({required this.path, this.title});

  final String path;
  final String? title;
}

class PlaylistDocument {
  const PlaylistDocument({required this.name, required this.entries});

  final String? name;
  final List<PlaylistEntry> entries;
}

PlaylistDocument parsePlaylistDocument(String source, String extension) {
  switch (extension.toLowerCase().replaceFirst('.', '')) {
    case 'm3u':
    case 'm3u8':
      return _parseM3u(source);
    case 'pls':
      return _parsePls(source);
    case 'b4s':
      return _parseB4s(source);
    case 'wpl':
      return _parseWpl(source);
    default:
      throw FormatException('Unsupported playlist format: $extension');
  }
}

PlaylistDocument _parseM3u(String source) {
  final entries = <PlaylistEntry>[];
  String? pendingTitle;
  String? name;
  for (final raw in source.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.toUpperCase().startsWith('#PLAYLIST:')) {
      name = line.substring(line.indexOf(':') + 1).trim();
      continue;
    }
    if (line.toUpperCase().startsWith('#EXTINF:')) {
      final comma = line.indexOf(',');
      pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : null;
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    entries.add(PlaylistEntry(path: line, title: pendingTitle));
    pendingTitle = null;
  }
  return PlaylistDocument(name: name, entries: entries);
}

PlaylistDocument _parsePls(String source) {
  final paths = <int, String>{};
  final titles = <int, String>{};
  String? name;
  for (final line in source.split(RegExp(r'\r?\n'))) {
    final path = RegExp(
      r'^\s*File(\d+)\s*=\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (path != null) {
      paths[int.parse(path.group(1)!)] = path.group(2)!.trim();
      continue;
    }
    final title = RegExp(
      r'^\s*Title(\d+)\s*=\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (title != null) {
      titles[int.parse(title.group(1)!)] = title.group(2)!.trim();
    }
  }
  final entries = paths.keys.toList()..sort();
  return PlaylistDocument(
    name: name,
    entries: [
      for (final index in entries)
        PlaylistEntry(path: paths[index]!, title: titles[index]),
    ],
  );
}

PlaylistDocument _parseB4s(String source) {
  final document = XmlDocument.parse(source);
  final playlist = document.descendants.whereType<XmlElement>().firstWhere(
    (element) => element.name.local.toLowerCase() == 'playlist',
    orElse: () =>
        throw const FormatException('B4S playlist element is missing.'),
  );
  String? attribute(XmlElement element, String name) {
    for (final value in element.attributes) {
      if (value.name.local.toLowerCase() == name.toLowerCase()) {
        return value.value;
      }
    }
    return null;
  }

  final entries = <PlaylistEntry>[];
  for (final element in playlist.descendants.whereType<XmlElement>()) {
    if (element.name.local.toLowerCase() != 'entry') continue;
    final path =
        attribute(element, 'Playstring') ??
        attribute(element, 'Filename') ??
        attribute(element, 'File');
    if (path == null || path.trim().isEmpty) continue;
    entries.add(
      PlaylistEntry(path: path.trim(), title: attribute(element, 'Title')),
    );
  }
  return PlaylistDocument(name: attribute(playlist, 'label'), entries: entries);
}

PlaylistDocument _parseWpl(String source) {
  final document = XmlDocument.parse(source);
  final body = document.descendants.whereType<XmlElement>().where(
    (element) => element.name.local.toLowerCase() == 'body',
  );
  if (body.isEmpty) throw const FormatException('WPL body element is missing.');
  final head = document.descendants.whereType<XmlElement>().where(
    (element) => element.name.local.toLowerCase() == 'head',
  );
  final titleElement = head.isEmpty
      ? null
      : head.first.descendants
            .whereType<XmlElement>()
            .where((element) => element.name.local.toLowerCase() == 'title')
            .firstOrNull;
  final entries = <PlaylistEntry>[];
  for (final element in body.first.descendants.whereType<XmlElement>()) {
    if (element.name.local.toLowerCase() != 'media') continue;
    final sourcePath =
        element.getAttribute('src') ??
        element.attributes
            .where((attribute) => attribute.name.local.toLowerCase() == 'src')
            .firstOrNull
            ?.value;
    if (sourcePath == null || sourcePath.trim().isEmpty) continue;
    entries.add(PlaylistEntry(path: sourcePath.trim()));
  }
  return PlaylistDocument(
    name: titleElement?.innerText.trim(),
    entries: entries,
  );
}

String resolvePlaylistPath(String entry, String playlistPath) {
  final value = entry.trim();
  if (value.isEmpty || value.startsWith('#')) return value;
  final uri = Uri.tryParse(value);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return value;
  }
  if (uri?.scheme == 'file') return uri!.toFilePath();
  if (File(value).isAbsolute ||
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value) ||
      value.startsWith(r'\\')) {
    return value;
  }
  final normalized = value.replaceAll(RegExp(r'[\\/]'), Platform.pathSeparator);
  return '${File(playlistPath).parent.path}${Platform.pathSeparator}$normalized';
}

String buildB4sPlaylist(
  List<PlaylistEntry> entries, {
  String name = 'NeonAmp playlist',
}) {
  final document = XmlDocument([
    XmlElement(XmlName.parts('WinampXML'), [], [
      XmlElement(
        XmlName.parts('playlist'),
        [
          XmlAttribute(XmlName.parts('num_entries'), '${entries.length}'),
          XmlAttribute(XmlName.parts('label'), name),
        ],
        [
          for (final entry in entries)
            XmlElement(XmlName.parts('entry'), [
              XmlAttribute(XmlName.parts('Playstring'), entry.path),
              XmlAttribute(XmlName.parts('Filename'), entry.path),
              XmlAttribute(
                XmlName.parts('Title'),
                entry.title ?? _playlistBasename(entry.path),
              ),
              XmlAttribute(XmlName.parts('Length'), '-1'),
            ]),
        ],
      ),
    ]),
  ]);
  return document.toXmlString(pretty: true, indent: '  ');
}

String buildWplPlaylist(
  List<PlaylistEntry> entries, {
  String name = 'NeonAmp playlist',
}) {
  final document = XmlDocument([
    XmlElement(XmlName.parts('smil'), [], [
      XmlElement(XmlName.parts('head'), [], [
        XmlElement(XmlName.parts('meta'), [
          XmlAttribute(XmlName.parts('name'), 'Generator'),
          XmlAttribute(XmlName.parts('content'), 'NeonAmp'),
        ]),
        XmlElement(XmlName.parts('meta'), [
          XmlAttribute(XmlName.parts('name'), 'ItemCount'),
          XmlAttribute(XmlName.parts('content'), '${entries.length}'),
        ]),
        XmlElement(XmlName.parts('title'), [], [XmlText(name)]),
      ]),
      XmlElement(XmlName.parts('body'), [], [
        XmlElement(XmlName.parts('seq'), [], [
          for (var index = 0; index < entries.length; index++)
            XmlElement(XmlName.parts('media'), [
              XmlAttribute(XmlName.parts('src'), entries[index].path),
              XmlAttribute(XmlName.parts('tid'), '$index'),
            ]),
        ]),
      ]),
    ]),
  ]);
  return document.toXmlString(pretty: true, indent: '  ');
}

String _playlistBasename(String path) =>
    path.split(RegExp(r'[/\\]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '');
