import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neonamp/main.dart';
import 'package:neonamp/dsp_local_player.dart';
import 'package:neonamp/equalizer_presets.dart';
import 'package:neonamp/asf_metadata.dart';
import 'package:neonamp/podcast_opml.dart';
import 'package:neonamp/cue_sheet.dart';
import 'package:neonamp/itunes_library.dart';
import 'package:neonamp/player_layout.dart';

Future<void> _writeOggFixture(File file, {required bool opus}) async {
  final packets = <List<int>>[
    opus
        ? [...ascii.encode('OpusHead'), 1, 1, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 0]
        : [
            1,
            ...ascii.encode('vorbis'),
            0,
            0,
            0,
            0,
            1,
            0x80,
            0xbb,
            0,
            0,
            ...List<int>.filled(12, 0),
            0xb8,
            1,
          ],
    opus
        ? [
            ...ascii.encode('OpusTags'),
            7,
            0,
            0,
            0,
            ...ascii.encode('NeonAmp'),
            0,
            0,
            0,
            0,
          ]
        : [
            3,
            ...ascii.encode('vorbis'),
            7,
            0,
            0,
            0,
            ...ascii.encode('NeonAmp'),
            0,
            0,
            0,
            0,
            1,
          ],
    if (!opus) [5, ...ascii.encode('vorbis'), 0],
    opus ? [0xf8, 0xff, 0xfe] : [0],
  ];
  final pages = <int>[];
  for (var i = 0; i < packets.length; i++) {
    final packet = packets[i];
    final page = <int>[
      ...ascii.encode('OggS'),
      0,
      i == 0
          ? 2
          : i == packets.length - 1
          ? 4
          : 0,
      ...List<int>.filled(8, 0),
      1,
      0,
      0,
      0,
      i,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      packet.length,
      ...packet,
    ];
    var crc = 0;
    for (final byte in page) {
      crc ^= byte << 24;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x80000000) != 0
            ? ((crc << 1) ^ 0x04c11db7) & 0xffffffff
            : (crc << 1) & 0xffffffff;
      }
    }
    page.setRange(22, 26, [
      crc & 0xff,
      (crc >> 8) & 0xff,
      (crc >> 16) & 0xff,
      (crc >> 24) & 0xff,
    ]);
    pages.addAll(page);
  }
  await file.writeAsBytes(pages);
}

List<int> _ebmlElementForTest(int id, List<int> payload) {
  var idWidth = 1;
  while (idWidth < 4 && id >= (1 << (idWidth * 8))) {
    idWidth++;
  }
  final idBytes = List<int>.generate(
    idWidth,
    (index) => (id >> ((idWidth - index - 1) * 8)) & 0xff,
  );
  var sizeWidth = 1;
  while (payload.length >= (1 << (7 * sizeWidth)) - 1) {
    sizeWidth++;
  }
  final sizeBytes = List<int>.filled(sizeWidth, 0);
  var size = payload.length;
  for (var index = sizeWidth - 1; index >= 0; index--) {
    sizeBytes[index] = size & 0xff;
    size >>= 8;
  }
  sizeBytes[0] |= 1 << (8 - sizeWidth);
  return [...idBytes, ...sizeBytes, ...payload];
}

List<int> _webmSimpleTagForTest(String name, String value) =>
    _ebmlElementForTest(0x67c8, [
      ..._ebmlElementForTest(0x45a3, utf8.encode(name)),
      ..._ebmlElementForTest(0x4487, utf8.encode(value)),
    ]);

bool _containsBytes(List<int> source, List<int> target) {
  for (var start = 0; start + target.length <= source.length; start++) {
    var matches = true;
    for (var offset = 0; offset < target.length; offset++) {
      if (source[start + offset] != target[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

List<int> _asfLe16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _asfLe32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> _asfLe64(int value) => [
  ..._asfLe32(value & 0xffffffff),
  ..._asfLe32(value >> 32),
];

List<int> _asfText(String value) => [
  for (final unit in value.codeUnits) ..._asfLe16(unit),
  0,
  0,
];

List<int> _asfObjectForTest(List<int> guid, List<int> data) => [
  ...guid,
  ..._asfLe64(24 + data.length),
  ...data,
];

List<int> _asfDescriptorForTest(String name, String value) => [
  ..._asfLe16(_asfText(name).length),
  ..._asfText(name),
  ..._asfLe16(0),
  ..._asfLe16(_asfText(value).length),
  ..._asfText(value),
];

List<int> _asfBinaryDescriptorForTest(String name, List<int> value) => [
  ..._asfLe16(_asfText(name).length),
  ..._asfText(name),
  ..._asfLe16(1),
  ..._asfLe16(value.length),
  ...value,
];

List<int> _asfFixture() {
  const headerGuid = [
    0x30,
    0x26,
    0xb2,
    0x75,
    0x8e,
    0x66,
    0xcf,
    0x11,
    0xa6,
    0xd9,
    0x00,
    0xaa,
    0x00,
    0x62,
    0xce,
    0x6c,
  ];
  const contentGuid = [
    0x33,
    0x26,
    0xb2,
    0x75,
    0x8e,
    0x66,
    0xcf,
    0x11,
    0xa6,
    0xd9,
    0x00,
    0xaa,
    0x00,
    0x62,
    0xce,
    0x6c,
  ];
  const extendedGuid = [
    0x40,
    0xa4,
    0xd0,
    0xd2,
    0x07,
    0xe3,
    0xd2,
    0x11,
    0x97,
    0xf0,
    0x00,
    0xa0,
    0xc9,
    0x5e,
    0xa8,
    0x50,
  ];
  const filePropertiesGuid = [
    0xa1,
    0xdc,
    0xab,
    0x8c,
    0x47,
    0xa9,
    0xcf,
    0x11,
    0x8e,
    0xe4,
    0x00,
    0xc0,
    0x0c,
    0x20,
    0x53,
    0x65,
  ];
  const headerExtensionGuid = [
    0xb5,
    0x03,
    0xbf,
    0x5f,
    0x2e,
    0xa9,
    0xcf,
    0x11,
    0x8e,
    0xe3,
    0x00,
    0xc0,
    0x0c,
    0x20,
    0x53,
    0x65,
  ];
  const metadataObjectGuid = [
    0xea,
    0xcb,
    0xf8,
    0xc5,
    0xaf,
    0x5b,
    0x77,
    0x48,
    0x84,
    0x67,
    0xaa,
    0x8c,
    0x44,
    0xfa,
    0x4c,
    0xca,
  ];
  const reservedGuid = [
    0x11,
    0xd2,
    0xd3,
    0xab,
    0xba,
    0xa9,
    0xcf,
    0x11,
    0x8e,
    0xe6,
    0x00,
    0xc0,
    0x0c,
    0x20,
    0x53,
    0x65,
  ];
  const description = ['Old title', 'Old artist', '', 'Keep description', ''];
  final contentPayload = <int>[
    for (final field in description) ..._asfLe16(_asfText(field).length),
    for (final field in description) ..._asfText(field),
  ];
  final content = _asfObjectForTest(contentGuid, contentPayload);
  final descriptors = [
    _asfDescriptorForTest('WM/Genre', 'Old genre'),
    _asfDescriptorForTest('CUSTOM', 'Preserve me'),
    _asfDescriptorForTest('REPLAYGAIN_TRACK_GAIN', '-5.5 dB'),
    _asfDescriptorForTest('REPLAYGAIN_ALBUM_GAIN', '-8.5 dB'),
    _asfBinaryDescriptorForTest('WM/Picture', [
      3,
      ..._asfLe32(3),
      ..._asfText('image/jpeg'),
      ..._asfText(''),
      1,
      2,
      3,
    ]),
  ];
  final extended = _asfObjectForTest(extendedGuid, [
    ..._asfLe16(descriptors.length),
    ...descriptors.expand((item) => item),
  ]);
  final fileProperties = _asfObjectForTest(filePropertiesGuid, [
    ...List<int>.filled(16, 0x42),
    ..._asfLe64(0),
    ...List<int>.filled(60, 0),
  ]);
  final opaque = _asfObjectForTest(List<int>.filled(16, 0x5a), [1, 2, 3, 4]);
  final customRecord = [
    ..._asfLe16(0),
    ..._asfLe16(0),
    ..._asfLe16(_asfText('CUSTOM_BINARY').length),
    ..._asfLe16(1),
    ..._asfLe32(2),
    ..._asfText('CUSTOM_BINARY'),
    0x11,
    0x22,
  ];
  final metadataObject = _asfObjectForTest(metadataObjectGuid, [
    ..._asfLe16(1),
    ...customRecord,
  ]);
  final headerExtension = _asfObjectForTest(headerExtensionGuid, [
    ...reservedGuid,
    ..._asfLe16(6),
    ..._asfLe32(metadataObject.length),
    ...metadataObject,
  ]);
  final children = [
    ...fileProperties,
    ...content,
    ...extended,
    ...headerExtension,
    ...opaque,
  ];
  final header = _asfObjectForTest(headerGuid, [
    ..._asfLe32(5),
    1,
    2,
    ...children,
  ]);
  final dataObject = [
    ...List<int>.filled(16, 0x75),
    ...List<int>.filled(256, 0xa5),
  ];
  return [...header, ...dataObject];
}

List<Uint8List> _readOggPackets(Uint8List source) {
  final packets = <Uint8List>[];
  final pending = <int>[];
  var offset = 0;
  while (offset + 27 <= source.length) {
    final segments = source[offset + 26];
    final headerEnd = offset + 27 + segments;
    final lacing = source.sublist(offset + 27, headerEnd);
    var bodyOffset = headerEnd;
    for (final size in lacing) {
      pending.addAll(source.sublist(bodyOffset, bodyOffset + size));
      bodyOffset += size;
      if (size < 255) {
        packets.add(Uint8List.fromList(pending));
        pending.clear();
      }
    }
    offset = bodyOffset;
  }
  return packets;
}

void main() {
  test('OPML podcast subscriptions import and export round-trip', () {
    const source = '''<?xml version="1.0"?>
<opml version="2.0"><body>
  <outline text="Tech &amp; Talk" xmlUrl="https://example.com/feed?a=1&amp;b=2" />
  <outline text='Other' xmlUrl='http://example.org/rss' />
  <outline text="Duplicate" xmlUrl="https://example.com/feed?a=1&amp;b=2" />
  <outline text="Invalid" xmlUrl="file:///tmp/feed.xml" />
</body></opml>''';
    final feeds = podcastFeedsFromOpml(source);
    expect(feeds, [
      'https://example.com/feed?a=1&b=2',
      'http://example.org/rss',
    ]);
    expect(podcastFeedsFromOpml(podcastFeedsToOpml(feeds)), feeds);
  });

  test('CUE parser resolves shared audio segments and track metadata', () {
    const cue = '''PERFORMER "Album Artist"
TITLE "Cue Album"
FILE "disc image.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Opening"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    PERFORMER "Guest Artist"
    TITLE "Second Track"
    INDEX 01 03:15:37
  TRACK 03 AUDIO
    INDEX 01 07:02:00
  TRACK 04 MODE1/2352
    INDEX 01 10:00:00
''';
    final cuePath = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}album.cue',
    ).absolute.path;
    final tracks = parseCueSheet(cue, cuePath);
    expect(tracks, hasLength(3));
    expect(
      tracks[0].filePath,
      File(
        '${File(cuePath).parent.path}${Platform.pathSeparator}disc image.flac',
      ).absolute.path,
    );
    expect(tracks[0].sourceFileName, 'disc image.flac');
    expect(tracks[0].start, Duration.zero);
    expect(
      tracks[0].end,
      const Duration(minutes: 3, seconds: 15, milliseconds: 493),
    );
    expect(tracks[0].title, 'Opening');
    expect(tracks[0].performer, 'Album Artist');
    expect(tracks[1].performer, 'Guest Artist');
    expect(tracks[1].album, 'Cue Album');
    expect(tracks[1].end, const Duration(minutes: 7, seconds: 2));
    expect(tracks[2].end, const Duration(minutes: 10));
  });

  test('CUE playback timing is relative to each source segment', () {
    expect(
      cueRelativePosition(
        const Duration(minutes: 3, seconds: 16),
        const Duration(minutes: 3, seconds: 15),
      ),
      const Duration(seconds: 1),
    );
    expect(
      cueRelativePosition(Duration.zero, const Duration(seconds: 30)),
      Duration.zero,
    );
    expect(
      cueSegmentDuration(
        const Duration(minutes: 12),
        start: const Duration(minutes: 3),
        end: const Duration(minutes: 7),
      ),
      const Duration(minutes: 4),
    );
    expect(
      cueSegmentDuration(
        const Duration(minutes: 12),
        start: const Duration(minutes: 8),
      ),
      const Duration(minutes: 4),
    );
  });

  test('shuffle advances to a different queued track', () {
    for (var selected = 0; selected < 5; selected++) {
      final results = <int>{
        for (var offset = 0; offset < 4; offset++)
          nextQueueIndex(
            selected: selected,
            length: 5,
            shuffle: true,
            shuffledOffset: offset,
          ),
      };
      expect(results, hasLength(4));
      expect(results, isNot(contains(selected)));
    }
  });

  test('sequential and single-track advance wrap correctly', () {
    expect(nextQueueIndex(selected: 2, length: 3, shuffle: false), 0);
    expect(nextQueueIndex(selected: 0, length: 1, shuffle: true), 0);
  });

  test('stereo balance clamps and labels both channel extremes', () {
    expect(normalizeStereoBalance(-2), -1);
    expect(normalizeStereoBalance(2), 1);
    expect(stereoBalanceLabel(-1), 'Left 100%');
    expect(stereoBalanceLabel(0), 'Center');
    expect(stereoBalanceLabel(.5), 'Right 50%');
  });

  test('video queue wraps in both directions and filters extensions', () {
    expect(wrappedVideoIndex(3, 3), 0);
    expect(wrappedVideoIndex(-1, 3), 2);
    expect(isSupportedVideoPath('clip.MP4'), isTrue);
    expect(isSupportedVideoPath('track.mp3'), isFalse);
    expect(() => wrappedVideoIndex(0, 0), throwsArgumentError);
  });

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

  test(
    '15-second seek controls clamp to the track and allow unknown duration',
    () {
      const duration = Duration(minutes: 3);
      expect(
        seekByOffset(
          position: const Duration(seconds: 8),
          duration: duration,
          offset: const Duration(seconds: -15),
        ),
        Duration.zero,
      );
      expect(
        seekByOffset(
          position: const Duration(seconds: 80),
          duration: duration,
          offset: const Duration(seconds: 15),
        ),
        const Duration(seconds: 95),
      );
      expect(
        seekByOffset(
          position: const Duration(seconds: 175),
          duration: duration,
          offset: const Duration(seconds: 15),
        ),
        duration,
      );
      expect(
        seekByOffset(
          position: const Duration(seconds: 40),
          duration: Duration.zero,
          offset: const Duration(seconds: 15),
        ),
        const Duration(seconds: 55),
      );
    },
  );

  test('player layout normalization preserves play and removes duplicates', () {
    expect(normalizePlayerControls(null), defaultPlayerControls);
    expect(
      normalizePlayerControls([
        'shuffle',
        'shuffle',
        'unknown-action',
        'forward15',
      ]),
      ['shuffle', 'playPause', 'forward15'],
    );
    expect(normalizePlayerControls(['playPause', 'sleep', 'playPause']), [
      'playPause',
      'sleep',
    ]);
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
    final artwork = Uint8List.fromList([
      0xff,
      0xd8,
      ...List<int>.generate(512, (index) => index & 0xff),
      0xff,
      0xd9,
    ]);
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
      final numbers = readContainerId3TrackDiscNumbers(updated);
      expect(numbers?.track, 2);
      expect(numbers?.trackTotal, 9);
      expect(numbers?.disc, 1);
      expect(numbers?.discTotal, 2);
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
      final numbers = readContainerId3TrackDiscNumbers(updated);
      expect(numbers?.track, 2);
      expect(numbers?.trackTotal, 9);
      expect(numbers?.disc, 1);
      expect(numbers?.discTotal, 2);
    },
  );

  test('AAC ID3 metadata edits preserve encoded audio frames', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-aac-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture.aac');
    final audioFrames = Uint8List.fromList([
      0xff,
      0xf1,
      0x50,
      0x80,
      0x01,
      0x7f,
      0xfc,
      ...List<int>.generate(64, (index) => (index * 17) & 0xff),
    ]);
    await file.writeAsBytes(audioFrames);
    const values = [
      'AAC Title',
      'Artist',
      'Album',
      'Electronic',
      '',
      '2026',
      '3',
      '12',
      '1',
      '2',
      'Lyrics',
    ];

    await writeTrackMetadata(file, values);
    var written = await file.readAsBytes();
    var tagSize =
        (written[6] << 21) |
        (written[7] << 14) |
        (written[8] << 7) |
        written[9];
    expect(ascii.decode(written.sublist(0, 3)), 'ID3');
    expect(written.sublist(10 + tagSize), audioFrames);
    var metadata = readMetadata(file);
    expect(metadata.title, 'AAC Title');
    expect(metadata.lyrics, 'Lyrics');

    await writeTrackMetadata(file, [...values]..[0] = 'Renamed AAC');
    written = await file.readAsBytes();
    tagSize =
        (written[6] << 21) |
        (written[7] << 14) |
        (written[8] << 7) |
        written[9];
    expect(written.sublist(10 + tagSize), audioFrames);
    metadata = readMetadata(file);
    expect(metadata.title, 'Renamed AAC');
    expect(metadata.lyrics, 'Lyrics');

    final artwork = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]);
    await writeAacArtwork(file, values, artwork, 'image/png');
    var updatedWithArtwork = readMetadata(file, getImage: true);
    expect(updatedWithArtwork.pictures.single.bytes, artwork);
    expect(updatedWithArtwork.lyrics, 'Lyrics');

    await writeTrackMetadata(file, [...values]..[0] = 'AAC Artwork Kept');
    written = await file.readAsBytes();
    tagSize =
        (written[6] << 21) |
        (written[7] << 14) |
        (written[8] << 7) |
        written[9];
    expect(written.sublist(10 + tagSize), audioFrames);
    updatedWithArtwork = readMetadata(file, getImage: true);
    expect(updatedWithArtwork.title, 'AAC Artwork Kept');
    expect(updatedWithArtwork.lyrics, 'Lyrics');
    expect(updatedWithArtwork.pictures.single.bytes, artwork);

    final untaggedFile = File('${directory.path}/untagged.aac');
    await untaggedFile.writeAsBytes(audioFrames);
    await writeAacArtwork(untaggedFile, values, artwork, 'image/png');
    final untaggedWritten = await untaggedFile.readAsBytes();
    final untaggedTagSize =
        (untaggedWritten[6] << 21) |
        (untaggedWritten[7] << 14) |
        (untaggedWritten[8] << 7) |
        untaggedWritten[9];
    expect(untaggedWritten.sublist(10 + untaggedTagSize), audioFrames);
    final untaggedMetadata = readMetadata(untaggedFile, getImage: true);
    expect(untaggedMetadata.title, 'AAC Title');
    expect(untaggedMetadata.lyrics, 'Lyrics');
    expect(untaggedMetadata.pictures.single.bytes, artwork);
  });

  test('WebM tag edits retain audio clusters and custom tags', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-webm-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture.webm');
    final cluster = _ebmlElementForTest(0x1f43b675, [0x81, 0x00, 0x00, 0x80]);
    final oldTag = _ebmlElementForTest(0x7373, [
      ..._webmSimpleTagForTest('TITLE', 'Old title'),
      ..._webmSimpleTagForTest('CUSTOM_LABEL', 'Keep this'),
    ]);
    final tags = _ebmlElementForTest(0x1254c367, oldTag);
    final segmentPayload = [...tags, ...cluster];
    await file.writeAsBytes([
      ..._ebmlElementForTest(0x1a45dfa3, []),
      0x18,
      0x53,
      0x80,
      0x67,
      0x01,
      ...List<int>.filled(7, 0xff), // Unknown-size Segment.
      ...segmentPayload,
    ]);
    const values = [
      'WebM title',
      'Artist',
      'Album',
      'Electronic',
      '',
      '2026',
      '4',
      '11',
      '2',
      '3',
      'Embedded lyrics',
    ];

    await writeTrackMetadata(file, values);
    var metadata = readMetadata(file);
    expect(metadata.title, 'WebM title');
    expect(metadata.artist, 'Artist');
    expect(metadata.album, 'Album');
    expect(metadata.genres, contains('Electronic'));
    expect(metadata.trackNumber, 4);
    expect(metadata.trackTotal, 11);
    expect(metadata.discNumber, 2);
    expect(metadata.totalDisc, 3);
    expect(metadata.lyrics, 'Embedded lyrics');
    var allMetadata = readAllMetadata(file) as VorbisMetadata;
    expect(allMetadata.title, ['WebM title']);
    expect(allMetadata.unknowns['CUSTOM_LABEL'], 'Keep this');
    expect(_containsBytes(await file.readAsBytes(), cluster), isTrue);

    await writeTrackMetadata(file, [...values]..[0] = 'Renamed WebM');
    metadata = readMetadata(file);
    expect(metadata.title, 'Renamed WebM');
    allMetadata = readAllMetadata(file) as VorbisMetadata;
    expect(allMetadata.title, ['Renamed WebM']);
    expect(allMetadata.unknowns['CUSTOM_LABEL'], 'Keep this');
    expect(_containsBytes(await file.readAsBytes(), cluster), isTrue);

    final finiteFile = File('${directory.path}/finite.mkv');
    final trailingVoid = _ebmlElementForTest(0xec, [0x5a, 0x01]);
    await finiteFile.writeAsBytes([
      ..._ebmlElementForTest(0x1a45dfa3, []),
      ..._ebmlElementForTest(0x18538067, cluster),
      ...trailingVoid,
    ]);
    await writeTrackMetadata(finiteFile, values);
    expect(readMetadata(finiteFile).title, 'WebM title');
    final finiteUpdated = await finiteFile.readAsBytes();
    expect(_containsBytes(finiteUpdated, cluster), isTrue);
    expect(
      finiteUpdated.sublist(finiteUpdated.length - trailingVoid.length),
      trailingVoid,
    );
  });

  test('folder scans recognize the metadata reader audio formats', () {
    expect(isAacAudioPath('music/track.AAC'), isTrue);
    expect(isMatroskaAudioPath('music/track.mka'), isTrue);
    expect(isSupportedLibraryAudioPath('recording.mka'), isTrue);
    expect(isSupportedLibraryAudioPath('recording.aiff'), isTrue);
    expect(isSupportedLibraryAudioPath('track.mkv'), isTrue);
    expect(isSupportedLibraryAudioPath('track.wma'), isTrue);
    expect(isVorbisAudioPath('recording.OGA'), isTrue);
    for (final extension in [
      'amr',
      'awb',
      'spx',
      'm4b',
      '3gp',
      'oga',
      'ogx',
      'mp1',
      'mp2',
    ]) {
      final path = 'recording.$extension';
      expect(isSupportedLibraryAudioPath(path), isTrue);
      expect(isCrossPlatformFallbackAudioPath(path), isTrue);
      expect(trackRequiresDspPlayback(path, equalizerEnabled: false), isTrue);
    }
    expect(isAsfAudioPath('track.WMA'), isTrue);
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

  test('ReplayGain uses track or album gain from ID3 and APE tags', () {
    final vorbis = VorbisMetadata()
      ..replayGainTrackGain.add('-7.0 dB')
      ..replayGainAlbumGain.add('-8.0 dB');
    final id3 = Mp3Metadata()
      ..customMetadata['replaygain_track_gain'] = '-6.25 dB'
      ..customMetadata['REPLAYGAIN_ALBUM_GAIN'] = '-9.0 dB';
    final ape = ApeMetadata()..unknowns['REPLAYGAIN_ALBUM_GAIN'] = '-4.5 dB';
    final brokenTrackGain = Mp3Metadata()
      ..customMetadata['REPLAYGAIN_TRACK_GAIN'] = 'invalid'
      ..customMetadata['REPLAYGAIN_ALBUM_GAIN'] = '-3.0 dB';

    expect(replayGainDbFromMetadata(vorbis), -7.0);
    expect(replayGainDbFromMetadata(id3), -6.25);
    expect(replayGainDbFromMetadata(ape), -4.5);
    expect(replayGainDbFromMetadata(brokenTrackGain), -3.0);
    expect(replayGainDbFromMetadata(ApeMetadata()), isNull);
  });

  test('recognizes OGG and Opus as writable Vorbis containers', () {
    expect(isVorbisAudioPath('music/track.ogg'), isTrue);
    expect(isVorbisAudioPath('music/track.OPUS'), isTrue);
    expect(isVorbisAudioPath('music/track.flac'), isFalse);
  });

  test(
    'WMA ASF metadata round-trips without changing media or unknown tags',
    () async {
      final directory = await Directory.systemTemp.createTemp('neonamp-asf-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/fixture.wma');
      await file.writeAsBytes(_asfFixture());
      final original = await file.readAsBytes();
      final originalHeaderSize = ByteData.sublistView(original)
          .getUint64(16, Endian.little);
      final before = readTrackMetadata(file);
      expect(before.title, 'Old title');
      expect(before.artist, 'Old artist');
      expect(before.genres, ['Old genre']);
      expect(readTrackMetadata(file, getImage: true).pictures.single.bytes, [
        1,
        2,
        3,
      ]);
      expect(readReplayGainDb(file), -5.5);

      await writeTrackMetadata(file, [
        'New 🎵 title',
        'New artist',
        'New album',
        'Electronic',
        '',
        '2024',
        '7',
        '12',
        '2',
        '3',
        'New lyrics',
      ]);
      expect(readTrackMetadata(file, getImage: true).pictures.single.bytes, [
        1,
        2,
        3,
      ]);
      expect(readReplayGainDb(file), -5.5);

      final replacementArtwork = Uint8List.fromList(
        List<int>.generate(70000, (index) => index & 0xff),
      );
      await writeAsfTags(
        file,
        [
          'New 🎵 title',
          'New artist',
          'New album',
          'Electronic',
          '',
          '2024',
          '7',
          '12',
          '2',
          '3',
          'New lyrics',
        ],
        artwork: replacementArtwork,
        artworkMimeType: 'image/png',
      );

      final updated = readTrackMetadata(file);
      expect(updated.title, 'New 🎵 title');
      expect(updated.artist, 'New artist');
      expect(updated.album, 'New album');
      expect(updated.genres, ['Electronic']);
      expect(updated.year?.year, 2024);
      expect(updated.trackNumber, 7);
      expect(updated.trackTotal, 12);
      expect(updated.discNumber, 2);
      expect(updated.totalDisc, 3);
      expect(updated.lyrics, 'New lyrics');
      final updatedPicture = readTrackMetadata(
        file,
        getImage: true,
      ).pictures.single;
      expect(updatedPicture.bytes, replacementArtwork);
      expect(updatedPicture.mimetype, 'image/png');

      final rewritten = await file.readAsBytes();
      final headerSize = ByteData.sublistView(rewritten)
          .getUint64(16, Endian.little);
      expect(
        rewritten.sublist(headerSize),
        original.sublist(originalHeaderSize),
      );
      expect(_containsBytes(rewritten, _asfText('Preserve me')), isTrue);
      expect(_containsBytes(rewritten, _asfText('Keep description')), isTrue);
      expect(_containsBytes(rewritten, _asfText('CUSTOM_BINARY')), isTrue);
      expect(_containsBytes(rewritten, [0x11, 0x22]), isTrue);
      const filePropertiesGuid = [
        0xa1,
        0xdc,
        0xab,
        0x8c,
        0x47,
        0xa9,
        0xcf,
        0x11,
        0x8e,
        0xe4,
        0x00,
        0xc0,
        0x0c,
        0x20,
        0x53,
        0x65,
      ];
      var filePropertiesOffset = -1;
      for (var index = 0; index + 16 <= rewritten.length; index++) {
        if (_containsBytes(
          rewritten.sublist(index, index + 16),
          filePropertiesGuid,
        )) {
          filePropertiesOffset = index;
          break;
        }
      }
      expect(filePropertiesOffset, greaterThanOrEqualTo(0));
      expect(
        ByteData.sublistView(rewritten)
            .getUint64(filePropertiesOffset + 40, Endian.little),
        rewritten.length,
      );
    },
  );

  test('OGG artwork edits round-trip and survive later tag edits', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-ogg-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture.ogg');
    await _writeOggFixture(file, opus: false);
    const values = [
      'Title',
      'Artist',
      'Album',
      'Electronic',
      '',
      '2026',
      '3',
      '12',
      '1',
      '2',
      'Lyrics',
    ];
    final artwork = Uint8List.fromList([
      0xff,
      0xd8,
      ...List<int>.generate(70000, (index) => index & 0xff),
      0xff,
      0xd9,
    ]);
    await writeVorbisTags(file, values, artwork: artwork);
    await writeTrackMetadata(file, [...values]..[0] = 'Renamed');

    final metadata = readMetadata(file, getImage: true);
    expect(metadata.title, 'Renamed');
    expect(metadata.lyrics, 'Lyrics');
    expect(metadata.trackNumber, 3);
    expect(metadata.trackTotal, 12);
    expect(metadata.discNumber, 1);
    expect(metadata.totalDisc, 2);
    expect(metadata.pictures.single.bytes, artwork);
  });

  test(
    'Opus artwork edits round-trip and preserve lyrics and audio packets',
    () async {
      final directory = await Directory.systemTemp.createTemp('neonamp-opus-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/fixture.opus');
      await _writeOggFixture(file, opus: true);
      final originalAudioPacket = _readOggPackets(await file.readAsBytes())
          .last;
      const values = [
        'Title',
        'Artist',
        'Album',
        'Electronic',
        '',
        '2026',
        '3',
        '12',
        '1',
        '2',
        'Lyrics',
      ];
      final artwork = Uint8List.fromList([
        0xff,
        0xd8,
        ...List<int>.generate(70000, (index) => index & 0xff),
        0xff,
        0xd9,
      ]);
      await writeVorbisTags(file, values, artwork: artwork);
      await writeTrackMetadata(file, [...values]..[0] = 'Renamed');

      final metadata = readMetadata(file, getImage: true);
      expect(metadata.title, 'Renamed');
      expect(metadata.lyrics, 'Lyrics');
      expect(metadata.trackNumber, 3);
      expect(metadata.trackTotal, 12);
      expect(metadata.discNumber, 1);
      expect(metadata.totalDisc, 2);
      expect(metadata.pictures.single.bytes, artwork);
      expect(
        _readOggPackets(await file.readAsBytes()).last,
        originalAudioPacket,
      );
    },
  );

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
      cueStartMs: 195493,
      cueEndMs: 422000,
    );
    final restored = Track.fromJson(original.toJson());
    expect(restored.year, 2026);
    expect(restored.trackNumber, 2);
    expect(restored.trackTotal, 9);
    expect(restored.discNumber, 1);
    expect(restored.discTotal, 2);
    expect(restored.lyrics, 'Words');
    expect(restored.cueStartMs, 195493);
    expect(restored.cueEndMs, 422000);
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

  testWidgets('phone layout gives the library more room than now playing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();

    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.text('QUEUE'), findsOneWidget);
    expect(find.text('Your library is quiet.'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('NOW PLAYING'),
        matching: find.byWidgetPredicate(
          (widget) => widget is SizedBox && widget.height == 72,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (final option in [
      'Visuals',
      'Settings',
      'Add folder',
      'Rescan library folders',
      'Import M3U, PLS, B4S, WPL, or ASX playlist',
      'Import iTunes XML library',
      'Export iTunes XML library',
      'Import CUE sheet',
      'Add stream URL',
      'Find internet radio',
      'Subscribe to podcast RSS',
      'Refresh podcasts',
      'Import podcast subscriptions (OPML)',
      'Export podcast subscriptions (OPML)',
      'Manage podcast subscriptions',
      'Equalizer',
      'Playback speed',
      'Customize player controls',
      'Choose skin',
      'Import skin package',
      'Import MIDI SoundFont for EQ',
      'Manage plugins',
      'Export M3U playlist',
      'Sync music to device folder',
      'Sleep timer',
      'Export PLS playlist',
      'Export Winamp B4S playlist',
      'Export WPL playlist',
      'Export ASX playlist',
      'Play videos',
    ]) {
      expect(find.text(option), findsOneWidget, reason: 'Menu option: $option');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android-style menu speed and equalizer actions persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Playback speed'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Playback speed'));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, '1.5×'));
    await tester.pump();
    expect(find.text('1.50×'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Equalizer'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Equalizer'));
    await tester.pump();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Rock').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Save preset'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'My Rock Curve');
    await tester.tap(find.text('Save').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));

    final preferences = await SharedPreferences.getInstance();
    final settings =
        jsonDecode(preferences.getString('settings')!) as Map<String, dynamic>;
    expect(settings['playbackSpeed'], 1.5);
    expect(settings['equalizerEnabled'], isTrue);
    expect(settings['eqPreset'], 'My Rock Curve');
    expect(settings['eqBands'], builtInEqualizerPresets['Rock']);
    expect(settings['customEqPresets'], {
      'My Rock Curve': builtInEqualizerPresets['Rock'],
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom equalizer presets load into the preset selector', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'settings': jsonEncode({
        'eqPreset': 'My saved curve',
        'customEqPresets': {
          'My saved curve': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        },
      }),
    });

    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Equalizer'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Equalizer'));
    await tester.pump();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('My saved curve').last, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom player controls restore and persist from the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'settings': jsonEncode({
        'playerControls': ['playPause', 'sleep', 'queue'],
      }),
    });
    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();
    expect(find.byTooltip('Sleep timer'), findsOneWidget);
    expect(find.byTooltip('Listening queue'), findsOneWidget);

    await tester.tap(find.byTooltip('Customize player controls'));
    await tester.pump();
    expect(find.text('Customize player controls'), findsOneWidget);
    await tester.tap(find.text('Save layout'));
    await tester.pump();

    final preferences = await SharedPreferences.getInstance();
    final settings =
        jsonDecode(preferences.getString('settings')!) as Map<String, dynamic>;
    expect(settings['playerControls'], ['playPause', 'sleep', 'queue']);
  });

  test('bookmark toggling distinguishes virtual CUE tracks', () {
    final first = Track(
      path: 'album.flac',
      name: 'First',
      cueStartMs: 0,
      cueEndMs: 60000,
      trackNumber: 1,
    );
    final second = Track(
      path: 'album.flac',
      name: 'Second',
      cueStartMs: 60000,
      cueEndMs: 120000,
      trackNumber: 2,
    );
    final oneBookmark = toggleTrackBookmark([], first);
    final twoBookmarks = toggleTrackBookmark(oneBookmark, second);

    expect(twoBookmarks, hasLength(2));
    expect(toggleTrackBookmark(twoBookmarks, first), [second]);
    expect(toggleTrackBookmark([], first), [first]);
  });

  test('iTunes XML library preserves metadata and named playlists', () {
    final sourceTrack = Track(
      path: 'C:\\Music\\Artist\\Song & Title.mp3',
      name: 'Song & Title',
      artist: 'An Artist',
      album: 'An Album',
      genre: 'Rock',
      year: 1998,
      trackNumber: 4,
      trackTotal: 11,
      discNumber: 1,
      discTotal: 2,
    );
    final xml = buildItunesLibrary(
      [sourceTrack.toJson()],
      {
        'Road Trip': [sourceTrack.path],
      },
    );
    final imported = parseItunesLibrary(xml);

    expect(imported.tracks, hasLength(1));
    expect(
      Track.fromJson(Map<String, dynamic>.from(imported.tracks.single))
          .toJson(),
      sourceTrack.toJson(),
    );
    expect(imported.playlists, {
      'Road Trip': [sourceTrack.path],
    });
  });

  test('iTunes XML rejects malformed data and skips missing tracks safely', () {
    expect(() => parseItunesLibrary('<not-a-plist/>'), throwsFormatException);
    expect(
      () => parseItunesLibrary('''
        <?xml version="1.0"?><plist version="1.0"><dict>
          <key>Tracks</key><dict></dict>
        </dict></plist>
      '''),
      throwsFormatException,
    );
  });

  test('imports standard iTunes plist dictionaries and file URLs', () {
    const xml = '''
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
        <key>Tracks</key><dict><key>42</key><dict>
          <key>Track ID</key><integer>42</integer>
          <key>Name</key><string>A &amp; B</string>
          <key>Artist</key><string>Example Artist</string>
          <key>Album</key><string>Example Album</string>
          <key>Genre</key><string>Alternative</string>
          <key>Year</key><integer>2004</integer>
          <key>Track Number</key><integer>3</integer>
          <key>Location</key>
          <string>file://localhost/C:/Music/Example%20Song.mp3</string>
        </dict></dict>
        <key>Playlists</key><array>
          <dict><key>Name</key><string>Library</string><key>Master</key><true/>
            <key>Playlist Items</key><array><dict><key>Track ID</key><integer>42</integer></dict></array>
          </dict>
          <dict><key>Name</key><string>Favorites</string>
            <key>Playlist Items</key><array><dict><key>Track ID</key><integer>42</integer></dict></array>
          </dict>
        </array>
      </dict></plist>
    ''';
    final imported = parseItunesLibrary(xml);

    expect(imported.tracks.single['path'], r'C:\Music\Example Song.mp3');
    expect(imported.tracks.single['name'], 'A & B');
    expect(imported.tracks.single['year'], 2004);
    expect(imported.playlists, {
      'Favorites': [r'C:\Music\Example Song.mp3'],
    });
  });

  testWidgets(
    'podcast manager persists unsubscribe without feed network access',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({
        'podcastFeeds': ['https://example.com/feed.xml'],
      });
      await tester.pumpWidget(const NeonAmpApp());
      await tester.pump();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Manage podcast subscriptions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('example.com'), findsOneWidget);

      await tester.tap(find.byTooltip('Unsubscribe'));
      await tester.pump();
      expect(find.text('No podcast subscriptions yet.'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('podcastFeeds'), isEmpty);
    },
  );

  testWidgets('equalizer exposes stereo balance on the wide layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const NeonAmpApp());
    await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Equalizer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Stereo balance · Center'), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);
    final balanceSlider = find.byWidgetPredicate(
      (widget) => widget is Slider && widget.min == -1 && widget.max == 1,
    );
    expect(balanceSlider, findsOneWidget);
    await tester.drag(balanceSlider, const Offset(1000, 0));
    await tester.pump();
    expect(find.text('Stereo balance · Right 100%'), findsOneWidget);
  });
}
