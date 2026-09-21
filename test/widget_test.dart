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
