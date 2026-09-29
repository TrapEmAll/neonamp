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

    test('parses UTF-8 BOM-prefixed M3U paths', () {
      final playlist = parsePlaylistDocument(
        '\ufeff#EXTM3U\n/song.mp3\n',
        'm3u',
      );
      expect(playlist.entries.single.path, '/song.mp3');
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

    test('skips malformed PLS indexes without rejecting valid entries', () {
      final playlist = parsePlaylistDocument(
        '[playlist]\nFilex=/bad.mp3\nFile2=/good.mp3\n',
        'pls',
      );
      expect(playlist.entries.map((entry) => entry.path), ['/good.mp3']);
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

    test('parses ASX stream references and playlist titles', () {
      const source =
          '''<ASX version="3.0"><HEAD><TITLE>Favorites &amp; More</TITLE></HEAD>
<ENTRY><TITLE>Station</TITLE><REF HREF="https://example.com/live"/></ENTRY>
<ENTRY><REF HREF="relative/song.mp3"/></ENTRY></ASX>''';
      final playlist = parsePlaylistDocument(source, '.asx');
      expect(playlist.name, 'Favorites & More');
      expect(playlist.entries.map((entry) => entry.path), [
        'https://example.com/live',
        'relative/song.mp3',
      ]);
      expect(playlist.entries.map((entry) => entry.title), ['Station', null]);
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
      expect(
        resolvePlaylistPath('HTTPS://example.com/radio', playlistPath),
        'HTTPS://example.com/radio',
      );
      expect(
        resolvePlaylistPath(
          'content://com.example.provider/document/42',
          playlistPath,
        ),
        'content://com.example.provider/document/42',
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

    test('ASX export round-trips entry paths, titles, and label', () {
      final xml = buildAsxPlaylist(entries, name: 'A & B');
      final parsed = parsePlaylistDocument(xml, 'asx');
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

    test('rejects malformed XML playlists', () {
      expect(
        () => parsePlaylistDocument('<smil>', 'wpl'),
        throwsFormatException,
      );
      expect(
        () => parsePlaylistDocument('<ASX>', 'asx'),
        throwsFormatException,
      );
      expect(() => parsePlaylistDocument('', 'unknown'), throwsFormatException);
    });
  });
}
