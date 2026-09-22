import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/playlist_formats.dart';

void main() {
  group('playlist import formats', () {
    test('parses M3U titles and named lists', () {
      final playlist = parsePlaylistDocument(
        '#EXTM3U\n#PLAYLIST:Road trip\n#EXTINF:184,Artist - Song\n../music/song.mp3\n',
        'm3u',
      );
      expect(playlist.name, 'Road trip');
      expect(playlist.entries.single.path, '../music/song.mp3');
      expect(playlist.entries.single.title, 'Artist - Song');
    });

    test('parses PLS entries in numeric order', () {
      final playlist = parsePlaylistDocument(
        '[playlist]\nFile2=second.mp3\nTitle2=Second\nFile1=first.mp3\nTitle1=First\n',
        'pls',
      );
      expect(playlist.entries.map((entry) => entry.path), [
        'first.mp3',
        'second.mp3',
      ]);
      expect(playlist.entries.map((entry) => entry.title), ['First', 'Second']);
    });

    test('parses Winamp B4S including escaped paths and titles', () {
      const source = '''<?xml version="1.0"?>
<WinampXML><playlist num_entries="1" label="Favorites &amp; More">
  <entry Playstring="music/a&amp;b.mp3" Filename="a&amp;b.mp3" Title="A &amp; B" Length="-1" />
</playlist></WinampXML>''';
      final playlist = parsePlaylistDocument(source, '.b4s');
      expect(playlist.name, 'Favorites & More');
      expect(playlist.entries.single.path, 'music/a&b.mp3');
      expect(playlist.entries.single.title, 'A & B');
    });

    test('parses WPL media sources and playlist title', () {
      const source = '''<smil><head><title>Workout</title></head><body><seq>
<media src="one.mp3" tid="0"/><media src="https://example.com/live" tid="1"/>
</seq></body></smil>''';
      final playlist = parsePlaylistDocument(source, 'wpl');
      expect(playlist.name, 'Workout');
      expect(playlist.entries.map((entry) => entry.path), [
        'one.mp3',
        'https://example.com/live',
      ]);
    });

    test('resolves relative paths beside the playlist but preserves absolute paths and URLs', () {
      final playlistPath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}lists${Platform.pathSeparator}mix.m3u';
      final expected =
          '${File(playlistPath).parent.path}${Platform.pathSeparator}music${Platform.pathSeparator}song.mp3';
      expect(resolvePlaylistPath('music/song.mp3', playlistPath), expected);
      expect(
        resolvePlaylistPath('https://example.com/radio', playlistPath),
        'https://example.com/radio',
      );
      const absolute = r'C:\Music\song.mp3';
      expect(resolvePlaylistPath(absolute, playlistPath), absolute);
    });
  });

  group('playlist export formats', () {
    const entries = [
      PlaylistEntry(path: r'C:\Music\A&B.mp3', title: 'A & B'),
      PlaylistEntry(path: 'https://example.com/live', title: 'Live stream'),
    ];

    test('Winamp B4S export round-trips entry data and label', () {
      final xml = buildB4sPlaylist(entries, name: 'A & B');
      final parsed = parsePlaylistDocument(xml, 'b4s');
      expect(parsed.name, 'A & B');
      expect(
        parsed.entries.map((entry) => entry.path),
        entries.map((entry) => entry.path),
      );
      expect(
        parsed.entries.map((entry) => entry.title),
        entries.map((entry) => entry.title),
      );
    });

    test('WPL export round-trips entry data and label', () {
      final xml = buildWplPlaylist(entries, name: 'A & B');
      final parsed = parsePlaylistDocument(xml, 'wpl');
      expect(parsed.name, 'A & B');
      expect(
        parsed.entries.map((entry) => entry.path),
        entries.map((entry) => entry.path),
      );
    });

    test('rejects malformed WPL XML and unsupported extensions', () {
      expect(
        () => parsePlaylistDocument('<smil>', 'wpl'),
        throwsFormatException,
      );
      expect(() => parsePlaylistDocument('', 'asx'), throwsFormatException);
    });
  });
}
