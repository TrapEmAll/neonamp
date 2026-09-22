import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:neonamp/main.dart';
import 'package:neonamp/dsp_local_player.dart';

void main() {
  test('normalizes SHOUTcast station records for the shared radio UI', () {
    final station = normalizeShoutcastStation({
      'ID': 42,
      'Name': 'Retro FM',
      'Genre': 'Pop',
      'Format': 'audio/mpeg',
      'Bitrate': 128,
      'Listeners': 99,
    });
    expect(station['name'], 'Retro FM');
    expect(station['source'], 'SHOUTcast');
    expect(station['shoutcastId'], 42);
    expect(station['codec'], 'audio/mpeg');
  });

  test('normalizes and merges radio directory station metadata', () {
    final radioBrowser = normalizeRadioBrowserStation({
      'name': 'Retro FM',
      'tags': 'synthwave,80s',
      'votes': 8,
      'bitrate': 128,
      'codec': 'MP3',
      'country': 'US',
      'url_resolved': 'HTTP://radio.example/stream',
    });
    final shoutcast = normalizeShoutcastStation({
      'ID': 7,
      'Name': 'Retro FM mirror',
      'Listeners': 12,
      'StreamUrl': 'http://radio.example/stream',
    });

    final merged = mergeRadioStations([radioBrowser, shoutcast]);

    expect(merged, hasLength(1));
    expect(merged.single['name'], 'Retro FM mirror');
    expect(merged.single['listeners'], 12);
  });

  test('portable plugins validate and round-trip equalizer presets', () {
    const bands = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 4.0, 3.0, 2.0, 1.0];
    const plugin = NeonAmpPlugin(
      id: 'community.synthwave',
      name: 'Synthwave Pack',
      version: '1.2.0',
      description: 'Community presets',
      capabilities: ['equalizer-presets'],
      equalizerPresets: {'Neon drive': bands},
    );

    final restored = NeonAmpPlugin.fromJson(plugin.toJson());

    expect(restored.id, plugin.id);
    expect(restored.capabilities, contains('equalizer-presets'));
    expect(restored.equalizerPresets['Neon drive'], bands);
  });

  test('portable plugins reject malformed equalizer presets', () {
    expect(
      () => NeonAmpPlugin.fromJson({
        'id': 'broken',
        'name': 'Broken',
        'equalizerPresets': {
          'Bad': [0, 1],
        },
      }),
      throwsFormatException,
    );
  });

  test('device sync creates safe, collision-free file names', () {
    expect(syncFileName(r'C:\Music\live:take?.mp3'), 'live_take_.mp3');
    final used = <String>{'track.mp3'};
    expect(nextSyncFileName('track.mp3', used), 'track (2).mp3');
    expect(nextSyncFileName('track.mp3', used), 'track (3).mp3');
  });

  test('audio conversion uses a safe M4A output name', () {
    expect(convertedM4aFileName(r'C:\Music\live:take?.flac'), 'live_take_.m4a');
  });

  test('sleep timer remaining duration is restart-safe', () {
    final now = DateTime(2026, 9, 21, 12);
    expect(
      sleepTimerRemaining(now.add(const Duration(minutes: 30)), now),
      const Duration(minutes: 30),
    );
    expect(
      sleepTimerRemaining(now.subtract(const Duration(seconds: 1)), now),
      Duration.zero,
    );
    expect(sleepTimerRemaining(null, now), isNull);
  });

  test('play history moves the newest track to the front and caps entries', () {
    expect(addToPlayHistory(['b', 'a'], 'a'), ['a', 'b']);
    expect(addToPlayHistory(['a', 'b', 'c'], 'd', maxEntries: 3), [
      'd',
      'a',
      'b',
    ]);
  });

  test('resume positions ignore the beginning of a track', () {
    expect(restoreResumePosition(null), isNull);
    expect(restoreResumePosition(3000), isNull);
    expect(restoreResumePosition(3001), const Duration(milliseconds: 3001));
  });

  test('AIFF ID3 tags include editable common fields', () {
    final tag = buildAiffId3Tag([
      'Title',
      'Artist',
      'Album',
      'Genre',
      '',
      '2026',
      '2',
      '9',
      '1',
      '2',
      'Lyrics',
    ]);
    expect(String.fromCharCodes(tag.sublist(0, 3)), 'ID3');
    expect(String.fromCharCodes(tag), contains('TIT2'));
    expect(String.fromCharCodes(tag), contains('TRCK'));
    expect(String.fromCharCodes(tag), contains('USLT'));
  });

  test('AIFF ID3 tags embed cover artwork in an APIC frame', () {
    final artwork = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
    final tag = buildAiffId3Tag(List.filled(11, ''), artwork: artwork);
    expect(String.fromCharCodes(tag), contains('APIC'));
    expect(tag, containsAll(artwork));
  });

  test(
    'AIFF metadata write round-trips while preserving the audio chunks',
    () async {
      final directory = await Directory.systemTemp.createTemp('neonamp-aiff-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/roundtrip.aiff');
      final chunks = <int>[
        ...ascii.encode('COMM'),
        0, 0, 0, 18,
        0, 1, // mono
        0, 0, 0, 0, // no sample frames
        0, 16, // 16-bit PCM
        0x40, 0x0e, 0xac, 0x44, 0, 0, 0, 0, 0, 0, // 44100 Hz
        ...ascii.encode('SSND'),
        0, 0, 0, 8,
        0, 0, 0, 0, // offset
        0, 0, 0, 0, // block size
      ];
      await file.writeAsBytes([
        ...ascii.encode('FORM'),
        ...[0, 0, 0, 4 + chunks.length],
        ...ascii.encode('AIFF'),
        ...chunks,
      ]);
      await writeAiffTags(file, [
        'Title',
        'Artist',
        'Album',
        'Genre',
        '',
        '2026',
        '2',
        '9',
        '1',
        '2',
        'Lyrics',
      ]);
      final artwork = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
      await writeAiffTags(file, [
        'Title',
        'Artist',
        'Album',
        'Genre',
        '',
        '2026',
        '2',
        '9',
        '1',
        '2',
        'Lyrics',
      ], artwork: artwork);
      await writeAiffTags(file, [
        'Renamed',
        'Artist',
        'Album',
        'Genre',
        '',
        '2026',
        '2',
        '9',
        '1',
        '2',
        'Lyrics',
      ]);
      final updated = await file.readAsBytes();
      expect(String.fromCharCodes(updated.sublist(12, 16)), 'COMM');
      expect(String.fromCharCodes(updated.sublist(38, 42)), 'SSND');
      expect(updated.sublist(12, 12 + chunks.length), chunks);
      expect(readMetadata(file, getImage: false).title, 'Renamed');
      expect(readMetadata(file, getImage: false).artist, 'Artist');
      expect(readAiffId3Picture(updated)?.$1, artwork);
      expect(readAiffId3Lyrics(updated), 'Lyrics');
    },
  );

  test(
    'WAV ID3 metadata and lyrics round-trip without changing audio chunks',
    () async {
      final directory = await Directory.systemTemp.createTemp('neonamp-wav-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/roundtrip.wav');
      final chunks = <int>[
        ...ascii.encode('fmt '), 16, 0, 0, 0,
        1, 0, 1, 0, // PCM, mono
        0x44, 0xac, 0, 0, // 44100 Hz
        0x88, 0x58, 1, 0, // byte rate
        2, 0, 16, 0, // block align and bits/sample
        ...ascii.encode('data'), 4, 0, 0, 0, 1, 2, 3, 4,
      ];
      await file.writeAsBytes([
        ...ascii.encode('RIFF'),
        0,
        0,
        0,
        0,
        ...ascii.encode('WAVE'),
        ...chunks,
      ]);
      final values = [
        'Title',
        'Artist',
        'Album',
        'Rock',
        '',
        '2026',
        '2',
        '9',
        '1',
        '2',
        'Lyrics',
      ];
      await writeWavTags(file, values);
      final art = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
      await writeWavTags(file, values, artwork: art);
      final renamed = [...values]..[0] = 'Renamed';
      await writeTrackMetadata(file, renamed);

      final updated = await file.readAsBytes();
      expect(updated.sublist(12, 12 + chunks.length), chunks);
      expect(readMetadata(file).title, 'Renamed');
      expect(readMetadata(file).artist, 'Artist');
      expect(readWavId3Lyrics(updated), 'Lyrics');
      expect(readAiffId3Picture(updated)?.$1, art);
    },
  );

  test('folder scans recognize the metadata reader audio formats', () {
    expect(isSupportedLibraryAudioPath('recording.aiff'), isTrue);
    expect(isSupportedLibraryAudioPath('track.mkv'), isTrue);
    expect(isSupportedLibraryAudioPath('cover.jpg'), isFalse);
  });

  test('ReplayGain parsing and volume normalization are deterministic', () {
    expect(parseReplayGainDb('-7.25 dB'), -7.25);
    expect(parseReplayGainDb('not a gain'), isNull);
    expect(
      playbackVolume(volume: 0.8, replayGainDb: -6, replayGainEnabled: true),
      closeTo(0.40095, 0.0001),
    );
    expect(
      playbackVolume(volume: 0.8, replayGainDb: 6, replayGainEnabled: true),
      1.0,
    );
  });

  test('recognizes OGG and Opus as writable Vorbis containers', () {
    expect(isVorbisAudioPath('music/track.ogg'), isTrue);
    expect(isVorbisAudioPath('music/track.OPUS'), isTrue);
    expect(isVorbisAudioPath('music/track.flac'), isFalse);
  });

  test('smart playlist rules round-trip through JSON', () {
    const original = SmartPlaylist(
      name: 'Synthwave favorites',
      rule: 'Genre',
      value: 'Synthwave',
      sortBy: 'Play count',
      descending: true,
      limit: 25,
      matchAll: false,
      criteria: [
        SmartCriterion(rule: 'Genre', value: 'Synthwave'),
        SmartCriterion(rule: 'Artist', value: 'The Midnight'),
      ],
    );

    final restored = SmartPlaylist.fromJson(original.toJson());

    expect(restored.name, original.name);
    expect(restored.rule, original.rule);
    expect(restored.value, original.value);
    expect(restored.sortBy, original.sortBy);
    expect(restored.descending, original.descending);
    expect(restored.limit, original.limit);
    expect(restored.matchAll, isFalse);
    expect(restored.effectiveCriteria, hasLength(2));
    expect(restored.effectiveCriteria.last.rule, 'Artist');
    expect(restored.effectiveCriteria.last.value, 'The Midnight');
  });

  test('track metadata fields round-trip through JSON', () {
    final original = Track(
      path: 'song.flac',
      name: 'Song',
      artist: 'Artist',
      album: 'Album',
      genre: 'Synthwave',
      year: 2026,
      trackNumber: 2,
      trackTotal: 9,
      discNumber: 1,
      discTotal: 2,
      lyrics: 'Words',
    );
    final restored = Track.fromJson(original.toJson());
    expect(restored.year, 2026);
    expect(restored.trackNumber, 2);
    expect(restored.trackTotal, 9);
    expect(restored.discNumber, 1);
    expect(restored.discTotal, 2);
    expect(restored.lyrics, 'Words');
  });

  test('skin packages round-trip through JSON', () {
    const original = ThemeSkin(
      name: 'Midnight Citrus',
      seedColor: Color(0xffb7ff4a),
      backgroundColor: Color(0xff10130b),
    );

    final restored = ThemeSkin.fromJson(original.toJson());

    expect(restored.name, original.name);
    expect(restored.seedColor, original.seedColor);
    expect(restored.backgroundColor, original.backgroundColor);
  });

  test('skin packages reject malformed colors', () {
    expect(
      () => ThemeSkin.fromJson({
        'name': 'Broken',
        'seedColor': 'blue',
        'backgroundColor': '#101010',
      }),
      throwsFormatException,
    );
  });

  test('DSP equalizer converts decibels to linear gain', () {
    expect(dspGainForDb(0), closeTo(1, 0.0001));
    expect(dspGainForDb(6), closeTo(1.995, 0.001));
    expect(dspGainForDb(12), closeTo(3.981, 0.001));
    expect(dspGainForDb(-12), closeTo(0.251, 0.001));
  });

  testWidgets('renders the empty NeonAmp player', (tester) async {
    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();
    expect(find.text('NEONAMP'), findsOneWidget);
    expect(find.text('Your library is quiet.'), findsOneWidget);
  });
}
