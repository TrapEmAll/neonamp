import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_soloud/flutter_soloud.dart' as soloud;
import 'package:path_provider/path_provider.dart';
import 'package:upnp_client/upnp_client.dart' show MediaRenderer;

import 'dsp_local_player.dart';
import 'video_player_page.dart';
import 'asf_metadata.dart';
import 'itunes_library.dart';
import 'player_layout.dart';
import 'podcast_opml.dart';
import 'cue_sheet.dart';
import 'dlna_cast.dart';
import 'playlist_formats.dart';
import 'tracker_modules.dart';
import 'windows_midi_player.dart';
import 'equalizer_presets.dart';
import 'playlist_library_resolution.dart';

const supportedVideoExtensions = {
  'avi',
  'mkv',
  'mov',
  'mp4',
  'mpeg',
  'mpg',
  'webm',
  'wmv',
};

bool isSupportedVideoPath(String path) =>
    supportedVideoExtensions.contains(path.split('.').last.toLowerCase());

int wrappedVideoIndex(int index, int length) {
  if (length <= 0) throw ArgumentError.value(length, 'length');
  return ((index % length) + length) % length;
}

bool isVorbisAudioPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return extension == 'ogg' || extension == 'opus';
}

bool isAiffAudioPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return extension == 'aif' || extension == 'aiff' || extension == 'aifc';
}

bool isWavAudioPath(String path) => path.split('.').last.toLowerCase() == 'wav';

bool isAacAudioPath(String path) => path.split('.').last.toLowerCase() == 'aac';

bool isAsfAudioPath(String path) => path.split('.').last.toLowerCase() == 'wma';

AudioMetadata readTrackMetadata(File file, {bool getImage = false}) =>
    isAsfAudioPath(file.path)
    ? readAsfMetadata(file, getImage: getImage)
    : readMetadata(file, getImage: getImage);

bool isMatroskaAudioPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return extension == 'webm' || extension == 'mkv' || extension == 'mka';
}

bool isSupportedLibraryAudioPath(String path) {
  const extensions = <String>{
    '.mp3',
    '.flac',
    '.wav',
    '.ogg',
    '.m4a',
    '.m4b',
    '.mp4',
    '.aac',
    '.wma',
    '.opus',
    '.ape',
    '.aif',
    '.aiff',
    '.aifc',
    '.mov',
    '.webm',
    '.mkv',
    '.mka',
  };
  final lowerPath = path.toLowerCase();
  final dot = lowerPath.lastIndexOf('.');
  return dot >= 0 &&
      (extensions.contains(lowerPath.substring(dot)) ||
          trackerModuleExtensions.contains(lowerPath.substring(dot + 1)) ||
          midiFileExtensions.contains(lowerPath.substring(dot + 1)));
}

bool isRemoteMediaPath(String path) {
  final scheme = Uri.tryParse(path)?.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

bool isContentMediaPath(String path) {
  return Uri.tryParse(path)?.scheme.toLowerCase() == 'content';
}

bool isUriMediaPath(String path) {
  return isRemoteMediaPath(path) || isContentMediaPath(path);
}

bool isHttpUri(Uri? uri) {
  final scheme = uri?.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}

int nextQueueIndex({
  required int selected,
  required int length,
  required bool shuffle,
  int? shuffledOffset,
}) {
  if (length <= 0) throw ArgumentError.value(length, 'length');
  if (selected < 0 || selected >= length) {
    throw RangeError.range(selected, 0, length - 1, 'selected');
  }
  if (!shuffle || length == 1) return (selected + 1) % length;
  final offset = shuffledOffset;
  if (offset == null) throw ArgumentError.notNull('shuffledOffset');
  if (offset < 0 || offset >= length - 1) {
    throw RangeError.range(offset, 0, length - 2, 'shuffledOffset');
  }
  return offset >= selected ? offset + 1 : offset;
}

double normalizeStereoBalance(double balance) => balance.clamp(-1.0, 1.0);

double normalizePlaybackSpeed(double speed) => speed.isFinite
    ? speed.clamp(0.5, 2.0).toDouble()
    : 1.0;

String stereoBalanceLabel(double balance) {
  final normalized = normalizeStereoBalance(balance);
  if (normalized == 0) return 'Center';
  final percentage = (normalized.abs() * 100).round();
  return '${normalized < 0 ? 'Left' : 'Right'} $percentage%';
}

List<int> _bigEndian32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

List<int> _littleEndian32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> _syncSafe32(int value) => [
  (value >> 21) & 0x7f,
  (value >> 14) & 0x7f,
  (value >> 7) & 0x7f,
  value & 0x7f,
];

List<int> _id3TextFrame(String id, String value) {
  if (value.isEmpty) return const [];
  final payload = <int>[3, ...utf8.encode(value)];
  return <int>[
    ...ascii.encode(id),
    ..._bigEndian32(payload.length),
    0,
    0,
    ...payload,
  ];
}

List<int> _id3LyricsFrame(String value) {
  if (value.trim().isEmpty) return const [];
  final payload = <int>[3, ...ascii.encode('eng'), 0, ...utf8.encode(value)];
  return <int>[
    ...ascii.encode('USLT'),
    ..._bigEndian32(payload.length),
    0,
    0,
    ...payload,
  ];
}

List<int> _id3PictureFrame(Uint8List bytes, String mimeType) {
  final payload = <int>[0, ...ascii.encode(mimeType), 0, 3, 0, ...bytes];
  return <int>[
    ...ascii.encode('APIC'),
    ..._bigEndian32(payload.length),
    0,
    0,
    ...payload,
  ];
}

Uint8List buildAiffId3Tag(
  List<String> values, {
  Uint8List? artwork,
  String artworkMimeType = 'image/jpeg',
}) {
  final frames = <int>[
    ..._id3TextFrame('TIT2', values[0]),
    ..._id3TextFrame('TPE1', values[1]),
    ..._id3TextFrame('TALB', values[2]),
    ..._id3TextFrame('TCON', values[3]),
    ..._id3TextFrame('TYER', values[5]),
    ..._id3TextFrame(
      'TRCK',
      values[7].isEmpty ? values[6] : '${values[6]}/${values[7]}',
    ),
    ..._id3TextFrame(
      'TPOS',
      values[9].isEmpty ? values[8] : '${values[8]}/${values[9]}',
    ),
    ..._id3LyricsFrame(values[10]),
    if (artwork != null) ..._id3PictureFrame(artwork, artworkMimeType),
  ];
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    ..._syncSafe32(frames.length),
    ...frames,
  ]);
}

String? readAiffId3Lyrics(Uint8List source) {
  if (source.length < 12 || ascii.decode(source.sublist(0, 4)) != 'FORM') {
    return null;
  }
  var offset = 12;
  while (offset + 8 <= source.length) {
    final chunkId = ascii.decode(source.sublist(offset, offset + 4));
    final chunkSize =
        (source[offset + 4] << 24) |
        (source[offset + 5] << 16) |
        (source[offset + 6] << 8) |
        source[offset + 7];
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + chunkSize;
    if (chunkSize < 0 || payloadEnd > source.length) return null;
    if (chunkId == 'ID3 ' && chunkSize >= 10) {
      final tag = source.sublist(payloadStart, payloadEnd);
      if (ascii.decode(tag.sublist(0, 3)) != 'ID3') return null;
      final tagSize =
          (tag[9] & 0x7f) |
          ((tag[8] & 0x7f) << 7) |
          ((tag[7] & 0x7f) << 14) |
          ((tag[6] & 0x7f) << 21);
      final tagEnd = math.min(tag.length, 10 + tagSize);
      var frameOffset = 10;
      while (frameOffset + 10 <= tagEnd) {
        final frameId = ascii.decode(tag.sublist(frameOffset, frameOffset + 4));
        if (frameId.trim().isEmpty) break;
        final frameSize =
            (tag[frameOffset + 4] << 24) |
            (tag[frameOffset + 5] << 16) |
            (tag[frameOffset + 6] << 8) |
            tag[frameOffset + 7];
        final frameStart = frameOffset + 10;
        final frameEnd = frameStart + frameSize;
        if (frameSize < 0 || frameEnd > tagEnd) return null;
        if (frameId == 'USLT' && frameSize >= 5) {
          final frame = tag.sublist(frameStart, frameEnd);
          final encoding = frame[0];
          if (encoding != 3) return null;
          final descriptionStart = 4;
          final descriptionEnd = frame.indexOf(0, descriptionStart);
          if (descriptionEnd < 0) return null;
          return utf8.decode(
            frame.sublist(descriptionEnd + 1),
            allowMalformed: true,
          );
        }
        frameOffset = frameEnd;
      }
      return null;
    }
    offset = payloadEnd + (chunkSize.isOdd ? 1 : 0);
  }
  return null;
}

({int? track, int? trackTotal, int? disc, int? discTotal})?
readContainerId3TrackDiscNumbers(Uint8List source) {
  if (source.length < 12) return null;
  final container = ascii.decode(source.sublist(0, 4));
  final isRiff = container == 'RIFF';
  if ((!isRiff && container != 'FORM') ||
      (isRiff && ascii.decode(source.sublist(8, 12)) != 'WAVE')) {
    return null;
  }
  var offset = 12;
  while (offset + 8 <= source.length) {
    final chunkId = ascii.decode(source.sublist(offset, offset + 4));
    final chunkSize = ByteData.sublistView(
      source,
      offset + 4,
      offset + 8,
    ).getUint32(0, isRiff ? Endian.little : Endian.big);
    final start = offset + 8;
    final end = start + chunkSize;
    if (end > source.length) return null;
    if (chunkId == 'ID3 ' && chunkSize >= 10) {
      final tag = source.sublist(start, end);
      if (ascii.decode(tag.sublist(0, 3)) != 'ID3') return null;
      final majorVersion = tag[3];
      if (majorVersion != 3 && majorVersion != 4) return null;
      final tagSize =
          (tag[9] & 0x7f) |
          ((tag[8] & 0x7f) << 7) |
          ((tag[7] & 0x7f) << 14) |
          ((tag[6] & 0x7f) << 21);
      final tagEnd = math.min(tag.length, 10 + tagSize);
      int? track;
      int? trackTotal;
      int? disc;
      int? discTotal;
      var frameOffset = 10;
      while (frameOffset + 10 <= tagEnd) {
        final id = ascii.decode(tag.sublist(frameOffset, frameOffset + 4));
        if (id.trim().isEmpty) break;
        final sizeView = ByteData.sublistView(
          tag,
          frameOffset + 4,
          frameOffset + 8,
        );
        final frameSize = majorVersion == 4
            ? (tag[frameOffset + 7] & 0x7f) |
                  ((tag[frameOffset + 6] & 0x7f) << 7) |
                  ((tag[frameOffset + 5] & 0x7f) << 14) |
                  ((tag[frameOffset + 4] & 0x7f) << 21)
            : sizeView.getUint32(0);
        final frameStart = frameOffset + 10;
        final frameEnd = frameStart + frameSize;
        if (frameEnd > tagEnd) return null;
        if ((id == 'TRCK' || id == 'TPOS') && frameSize > 1) {
          final encoding = tag[frameStart];
          String value;
          if (encoding == 3) {
            value = utf8.decode(
              tag.sublist(frameStart + 1, frameEnd),
              allowMalformed: true,
            );
          } else if (encoding == 0) {
            value = latin1.decode(tag.sublist(frameStart + 1, frameEnd));
          } else {
            value = '';
          }
          final parts = value.replaceAll('\u0000', '').split('/');
          final number = int.tryParse(parts.first.trim());
          final total = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
          if (id == 'TRCK') {
            track = number;
            trackTotal = total;
          } else {
            disc = number;
            discTotal = total;
          }
        }
        frameOffset = frameEnd;
      }
      return (
        track: track,
        trackTotal: trackTotal,
        disc: disc,
        discTotal: discTotal,
      );
    }
    offset = end + (chunkSize.isOdd ? 1 : 0);
  }
  return null;
}

String? readWavId3Lyrics(Uint8List source) {
  if (source.length < 12 ||
      ascii.decode(source.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(source.sublist(8, 12)) != 'WAVE') {
    return null;
  }
  var offset = 12;
  while (offset + 8 <= source.length) {
    final chunkId = ascii.decode(source.sublist(offset, offset + 4));
    final chunkSize = ByteData.sublistView(
      source,
      offset + 4,
      offset + 8,
    ).getUint32(0, Endian.little);
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + chunkSize;
    if (payloadEnd > source.length) return null;
    if ((chunkId == 'ID3 ' || chunkId == 'id3 ') && chunkSize >= 10) {
      final tag = source.sublist(payloadStart, payloadEnd);
      if (ascii.decode(tag.sublist(0, 3)) != 'ID3') return null;
      final tagSize =
          (tag[9] & 0x7f) |
          ((tag[8] & 0x7f) << 7) |
          ((tag[7] & 0x7f) << 14) |
          ((tag[6] & 0x7f) << 21);
      final tagEnd = math.min(tag.length, 10 + tagSize);
      var frameOffset = 10;
      while (frameOffset + 10 <= tagEnd) {
        final frameId = ascii.decode(tag.sublist(frameOffset, frameOffset + 4));
        if (frameId.trim().isEmpty) break;
        final frameSize = ByteData.sublistView(
          tag,
          frameOffset + 4,
          frameOffset + 8,
        ).getUint32(0);
        final frameStart = frameOffset + 10;
        final frameEnd = frameStart + frameSize;
        if (frameEnd > tagEnd) return null;
        if (frameId == 'USLT' && frameSize >= 5 && tag[frameStart] == 3) {
          final descriptionEnd = tag.indexOf(0, frameStart + 4);
          if (descriptionEnd < 0 || descriptionEnd >= frameEnd) return null;
          return utf8.decode(
            tag.sublist(descriptionEnd + 1, frameEnd),
            allowMalformed: true,
          );
        }
        frameOffset = frameEnd;
      }
      return null;
    }
    offset = payloadEnd + (chunkSize.isOdd ? 1 : 0);
  }
  return null;
}

(Uint8List, String)? readAiffId3Picture(Uint8List source) {
  if (source.length < 12 ||
      (ascii.decode(source.sublist(0, 4)) != 'FORM' &&
          (ascii.decode(source.sublist(0, 4)) != 'RIFF' ||
              ascii.decode(source.sublist(8, 12)) != 'WAVE'))) {
    return null;
  }
  var offset = 12;
  while (offset + 8 <= source.length) {
    final chunkId = ascii.decode(source.sublist(offset, offset + 4));
    final chunkSize = ByteData.sublistView(source, offset + 4, offset + 8)
        .getUint32(
          0,
          ascii.decode(source.sublist(0, 4)) == 'RIFF'
              ? Endian.little
              : Endian.big,
        );
    final payloadStart = offset + 8;
    final payloadEnd = payloadStart + chunkSize;
    if (payloadEnd > source.length) return null;
    if (chunkId == 'ID3 ' && chunkSize >= 10) {
      final tag = source.sublist(payloadStart, payloadEnd);
      if (ascii.decode(tag.sublist(0, 3)) != 'ID3') return null;
      final tagSize =
          (tag[9] & 0x7f) |
          ((tag[8] & 0x7f) << 7) |
          ((tag[7] & 0x7f) << 14) |
          ((tag[6] & 0x7f) << 21);
      final tagEnd = math.min(tag.length, 10 + tagSize);
      var frameOffset = 10;
      while (frameOffset + 10 <= tagEnd) {
        final frameId = ascii.decode(tag.sublist(frameOffset, frameOffset + 4));
        if (frameId.trim().isEmpty) break;
        final frameSize = ByteData.sublistView(
          tag,
          frameOffset + 4,
          frameOffset + 8,
        ).getUint32(0);
        final frameStart = frameOffset + 10;
        final frameEnd = frameStart + frameSize;
        if (frameEnd > tagEnd) return null;
        if (frameId == 'APIC' && frameSize >= 5 && tag[frameStart] == 0) {
          final mimeStart = frameStart + 1;
          final mimeEnd = tag.indexOf(0, mimeStart);
          if (mimeEnd < 0 || mimeEnd + 2 >= frameEnd) return null;
          final descriptionStart = mimeEnd + 2;
          final descriptionEnd = tag.indexOf(0, descriptionStart);
          if (descriptionEnd < 0 || descriptionEnd + 1 > frameEnd) return null;
          return (
            Uint8List.fromList(tag.sublist(descriptionEnd + 1, frameEnd)),
            ascii.decode(tag.sublist(mimeStart, mimeEnd)),
          );
        }
        frameOffset = frameEnd;
      }
      return null;
    }
    offset = payloadEnd + (chunkSize.isOdd ? 1 : 0);
  }
  return null;
}

Future<void> writeAiffTags(
  File file,
  List<String> values, {
  Uint8List? artwork,
  String artworkMimeType = 'image/jpeg',
}) async {
  final source = await file.readAsBytes();
  if (source.length < 12 || ascii.decode(source.sublist(0, 4)) != 'FORM') {
    throw const FormatException('Not an AIFF container');
  }
  if (artwork == null) {
    final picture = readAiffId3Picture(source);
    if (picture != null) {
      artwork = picture.$1;
      artworkMimeType = picture.$2;
    }
  }
  final body = <int>[];
  var offset = 12;
  while (offset + 8 <= source.length) {
    final chunkId = ascii.decode(source.sublist(offset, offset + 4));
    final chunkSize =
        (source[offset + 4] << 24) |
        (source[offset + 5] << 16) |
        (source[offset + 6] << 8) |
        source[offset + 7];
    final end = offset + 8 + chunkSize;
    if (chunkSize < 0 || end > source.length) {
      throw const FormatException('Truncated AIFF chunk');
    }
    final next = end + (chunkSize.isOdd ? 1 : 0);
    if (chunkId != 'ID3 ') body.addAll(source.sublist(offset, next));
    offset = next;
  }
  if (offset != source.length) {
    throw const FormatException('Malformed AIFF chunk alignment');
  }
  final tag = buildAiffId3Tag(
    values,
    artwork: artwork,
    artworkMimeType: artworkMimeType,
  );
  final tagChunk = <int>[
    ...ascii.encode('ID3 '),
    ..._bigEndian32(tag.length),
    ...tag,
    if (tag.length.isOdd) 0,
  ];
  final output = <int>[...source.sublist(0, 12), ...body, ...tagChunk];
  final formSize = output.length - 8;
  output.setRange(4, 8, _bigEndian32(formSize));
  await _replaceFileAtomically(file, output);
}

Future<void> writeWavTags(
  File file,
  List<String> values, {
  Uint8List? artwork,
  String artworkMimeType = 'image/jpeg',
}) async {
  final source = await file.readAsBytes();
  if (source.length < 12 ||
      ascii.decode(source.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(source.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Not a RIFF/WAVE container');
  }
  if (artwork == null) {
    final existing = readAiffId3Picture(source);
    if (existing != null) {
      artwork = existing.$1;
      artworkMimeType = existing.$2;
    }
  }
  final body = <int>[];
  var offset = 12;
  while (offset + 8 <= source.length) {
    final chunkId = ascii.decode(source.sublist(offset, offset + 4));
    final chunkSize = ByteData.sublistView(
      source,
      offset + 4,
      offset + 8,
    ).getUint32(0, Endian.little);
    final end = offset + 8 + chunkSize;
    if (end > source.length) throw const FormatException('Truncated WAV chunk');
    final next = end + (chunkSize.isOdd ? 1 : 0);
    if (next > source.length) {
      throw const FormatException('Malformed WAV chunk padding');
    }
    if (chunkId != 'ID3 ' && chunkId != 'id3 ') {
      body.addAll(source.sublist(offset, next));
    }
    offset = next;
  }
  if (offset != source.length) {
    throw const FormatException('Malformed WAV chunk alignment');
  }
  final tag = buildAiffId3Tag(
    values,
    artwork: artwork,
    artworkMimeType: artworkMimeType,
  );
  final tagChunk = <int>[
    ...ascii.encode('ID3 '),
    ..._littleEndian32(tag.length),
    ...tag,
    if (tag.length.isOdd) 0,
  ];
  final output = <int>[...source.sublist(0, 12), ...body, ...tagChunk];
  output.setRange(4, 8, _littleEndian32(output.length - 8));
  await _replaceFileAtomically(file, output);
}

double? parseReplayGainDb(String? value) {
  if (value == null) return null;
  final match = RegExp(r'[-+]?\d+(?:\.\d+)?').firstMatch(value);
  return match == null ? null : double.tryParse(match.group(0)!);
}

double playbackVolume({
  required double volume,
  required double? replayGainDb,
  required bool replayGainEnabled,
}) {
  if (!replayGainEnabled || replayGainDb == null) return volume;
  final multiplier = math.pow(10, replayGainDb / 20).toDouble();
  return (volume * multiplier).clamp(0.0, 1.0).toDouble();
}

class _OggPage {
  _OggPage(this.flags, this.granule, this.serial, this.sequence);

  final int flags;
  final int granule;
  final int serial;
  final int sequence;
  final packets = <List<int>>[];
}

List<int> _vorbisPictureComment(Uint8List image, String mimeType) {
  final mime = ascii.encode(mimeType);
  final description = ascii.encode('Album cover');
  final fields = <int>[
    3, 0, 0, 0, // front cover picture type
    ..._bigEndian32(mime.length), ...mime,
    ..._bigEndian32(description.length), ...description,
    ...List<int>.filled(16, 0), // dimensions, color depth, indexed colors
    ..._bigEndian32(image.length), ...image,
  ];
  return ascii.encode(base64.encode(fields));
}

List<int> _oggPageBytes({
  required int flags,
  required int granule,
  required int serial,
  required int sequence,
  required List<int> lacing,
  required List<int> body,
}) {
  final header = <int>[
    ...ascii.encode('OggS'),
    0,
    flags,
    ...List<int>.generate(8, (i) => (granule >> (i * 8)) & 0xff),
    ..._littleEndian32(serial),
    ..._littleEndian32(sequence),
    0,
    0,
    0,
    0,
    lacing.length,
    ...lacing,
  ];
  final page = <int>[...header, ...body];
  var checksum = 0;
  for (final byte in page) {
    checksum ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      checksum = (checksum & 0x80000000) != 0
          ? ((checksum << 1) ^ 0x04c11db7) & 0xffffffff
          : (checksum << 1) & 0xffffffff;
    }
  }
  page.setRange(22, 26, _littleEndian32(checksum));
  return page;
}

Uint8List _rewriteOggComments(
  Uint8List source,
  List<String> values, {
  Uint8List? artwork,
  String artworkMimeType = 'image/jpeg',
}) {
  final pages = <_OggPage>[];
  final pending = <int>[];
  var offset = 0;
  while (offset < source.length) {
    if (offset + 27 > source.length ||
        ascii.decode(source.sublist(offset, offset + 4)) != 'OggS' ||
        source[offset + 4] != 0) {
      throw const FormatException('Malformed Ogg page header');
    }
    final segmentCount = source[offset + 26];
    final headerEnd = offset + 27 + segmentCount;
    if (headerEnd > source.length) {
      throw const FormatException('Truncated Ogg lacing table');
    }
    final lacing = source.sublist(offset + 27, headerEnd);
    final bodyLength = lacing.fold<int>(0, (sum, size) => sum + size);
    final pageEnd = headerEnd + bodyLength;
    if (pageEnd > source.length) {
      throw const FormatException('Truncated Ogg page body');
    }
    final view = ByteData.sublistView(source, offset);
    final page = _OggPage(
      source[offset + 5],
      view.getUint64(6, Endian.little),
      view.getUint32(14, Endian.little),
      view.getUint32(18, Endian.little),
    );
    if (pages.isNotEmpty && page.serial != pages.first.serial) {
      throw const FormatException('Multiplexed Ogg streams are not supported');
    }
    var bodyOffset = headerEnd;
    for (final size in lacing) {
      pending.addAll(source.sublist(bodyOffset, bodyOffset + size));
      bodyOffset += size;
      if (size < 255) {
        page.packets.add(List<int>.from(pending));
        pending.clear();
      }
    }
    pages.add(page);
    offset = pageEnd;
  }
  if (pending.isNotEmpty || pages.isEmpty) {
    throw const FormatException('Incomplete Ogg packet');
  }

  final allPackets = <(int, List<int>)>[];
  for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    for (final packet in pages[pageIndex].packets) {
      allPackets.add((pageIndex, packet));
    }
  }
  if (allPackets.length < 2) {
    throw const FormatException('Ogg comment packet is missing');
  }
  final identification = allPackets.first.$2;
  final oldComments = allPackets[1].$2;
  final isOpus =
      ascii.decode(oldComments.take(8).toList(), allowInvalid: true) ==
      'OpusTags';
  final prefixLength = isOpus ? 8 : 7;
  final validIdentification = isOpus
      ? ascii.decode(identification.take(8).toList(), allowInvalid: true) ==
            'OpusHead'
      : identification.length >= 7 &&
            ascii.decode(identification.sublist(0, 7), allowInvalid: true) ==
                '\x01vorbis';
  if (!validIdentification ||
      oldComments.length < prefixLength ||
      (!isOpus &&
          ascii.decode(oldComments.sublist(0, 7), allowInvalid: true) !=
              '\x03vorbis')) {
    throw const FormatException('Unsupported Ogg comment packet');
  }
  var cursor = prefixLength;
  int takeUint32() {
    if (cursor + 4 > oldComments.length) {
      throw const FormatException('Malformed Ogg comments');
    }
    final value = ByteData.sublistView(
      Uint8List.fromList(oldComments),
      cursor,
      cursor + 4,
    ).getUint32(0, Endian.little);
    cursor += 4;
    return value;
  }

  final vendorLength = takeUint32();
  if (cursor + vendorLength > oldComments.length) {
    throw const FormatException('Malformed Ogg vendor string');
  }
  final vendor = oldComments.sublist(cursor, cursor + vendorLength);
  cursor += vendorLength;
  final commentCount = takeUint32();
  final comments = <String>[];
  for (var i = 0; i < commentCount; i++) {
    final length = takeUint32();
    if (cursor + length > oldComments.length) {
      throw const FormatException('Malformed Ogg comment');
    }
    comments.add(
      utf8.decode(
        oldComments.sublist(cursor, cursor + length),
        allowMalformed: true,
      ),
    );
    cursor += length;
  }
  const managed = {
    'TITLE',
    'ARTIST',
    'ALBUM',
    'GENRE',
    'DATE',
    'YEAR',
    'TRACKNUMBER',
    'TRACKTOTAL',
    'TOTALTRACKS',
    'DISCNUMBER',
    'DISCTOTAL',
    'TOTALDISCS',
    'LYRICS',
  };
  comments.removeWhere((comment) {
    final separator = comment.indexOf('=');
    return separator > 0 &&
        managed.contains(comment.substring(0, separator).toUpperCase());
  });
  if (artwork != null) {
    comments.removeWhere((comment) {
      final separator = comment.indexOf('=');
      return separator > 0 &&
          const {
            'METADATA_BLOCK_PICTURE',
            'COVERART',
            'COVERARTMIME',
          }.contains(comment.substring(0, separator).toUpperCase());
    });
  }
  void add(String key, String value) {
    if (value.trim().isNotEmpty) comments.add('$key=$value');
  }

  add('TITLE', values[0]);
  add('ARTIST', values[1]);
  add('ALBUM', values[2]);
  add('GENRE', values[3]);
  add('DATE', values[5]);
  add('TRACKNUMBER', values[6]);
  add('TRACKTOTAL', values[7]);
  add('DISCNUMBER', values[8]);
  add('DISCTOTAL', values[9]);
  add('LYRICS', values[10]);
  if (artwork != null) {
    comments.add(
      'METADATA_BLOCK_PICTURE=${ascii.decode(_vorbisPictureComment(artwork, artworkMimeType))}',
    );
  }
  final replacement = <int>[
    ...oldComments.sublist(0, prefixLength),
    ..._littleEndian32(vendor.length),
    ...vendor,
    ..._littleEndian32(comments.length),
  ];
  for (final comment in comments) {
    final bytes = utf8.encode(comment);
    replacement.addAll([..._littleEndian32(bytes.length), ...bytes]);
  }
  if (!isOpus) replacement.add(1);
  allPackets[1] = (allPackets[1].$1, replacement);

  final groupedPackets = List.generate(pages.length, (_) => <List<int>>[]);
  for (final (pageIndex, packet) in allPackets) {
    groupedPackets[pageIndex].add(packet);
  }
  final output = <int>[];
  var outputSequence = pages.first.sequence;
  for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final group = groupedPackets[pageIndex];
    if (group.isEmpty) continue;
    final segments = <(int, List<int>, bool)>[];
    for (final packet in group) {
      var position = 0;
      while (packet.length - position >= 255) {
        segments.add((
          255,
          packet.sublist(position, position + 255),
          position > 0,
        ));
        position += 255;
      }
      segments.add((
        packet.length - position,
        packet.sublist(position),
        position > 0,
      ));
    }
    var segmentIndex = 0;
    var first = true;
    while (segmentIndex < segments.length) {
      final endSegment = math.min(segmentIndex + 255, segments.length);
      final pageSegments = segments.sublist(segmentIndex, endSegment);
      final lacing = pageSegments.map((segment) => segment.$1).toList();
      final body = <int>[];
      for (final segment in pageSegments) {
        body.addAll(segment.$2);
      }
      final pageIsLast = endSegment == segments.length;
      var flags = first && pageIndex == 0 ? 2 : 0;
      if (pageSegments.first.$3) flags |= 1;
      if (pageIsLast && pages[pageIndex].flags & 4 != 0) flags |= 4;
      final granule = pageIsLast
          ? pages[pageIndex].granule
          : 0xffffffffffffffff;
      output.addAll(
        _oggPageBytes(
          flags: flags,
          granule: granule,
          serial: pages[pageIndex].serial,
          sequence: outputSequence++,
          lacing: lacing,
          body: body,
        ),
      );
      segmentIndex = endSegment;
      first = false;
    }
  }
  return Uint8List.fromList(output);
}

Future<void> writeVorbisTags(
  File file,
  List<String> values, {
  Uint8List? artwork,
  String artworkMimeType = 'image/jpeg',
}) async {
  final source = await file.readAsBytes();
  final output = _rewriteOggComments(
    source,
    values,
    artwork: artwork,
    artworkMimeType: artworkMimeType,
  );
  await _replaceFileAtomically(file, output);
}

Future<void> writeAacTags(File file, List<String> values) async {
  final source = await file.readAsBytes();
  final hasLeadingId3 =
      source.length >= 3 &&
      source[0] == 0x49 &&
      source[1] == 0x44 &&
      source[2] == 0x33;
  if (hasLeadingId3) {
    _updateCommonTrackMetadata(file, values);
    await _writeAacLyricsFrame(file, values[10]);
    return;
  }

  // ID3v2 is the established metadata convention for ADTS AAC files. Keep the
  // encoded AAC frames byte-for-byte intact and prepend an ID3 tag.
  await _replaceFileAtomically(file, [...buildAiffId3Tag(values), ...source]);
}

Future<void> writeAacArtwork(
  File file,
  List<String> values,
  Uint8List artwork,
  String mimeType,
) async {
  final source = await file.readAsBytes();
  final hasLeadingId3 =
      source.length >= 3 &&
      source[0] == 0x49 &&
      source[1] == 0x44 &&
      source[2] == 0x33;
  if (!hasLeadingId3) {
    await _replaceFileAtomically(file, [
      ...buildAiffId3Tag(values, artwork: artwork, artworkMimeType: mimeType),
      ...source,
    ]);
    return;
  }
  updateMetadata(file, (metadata) {
    metadata.setPictures([Picture(artwork, mimeType, PictureType.coverFront)]);
  });
  await _writeAacLyricsFrame(file, values[10]);
}

Future<void> _writeAacLyricsFrame(File file, String lyrics) async {
  final source = await file.readAsBytes();
  if (source.length < 10 ||
      source[0] != 0x49 ||
      source[1] != 0x44 ||
      source[2] != 0x33 ||
      source[3] != 4) {
    throw const FormatException('AAC ID3 tag is not a writable ID3v2.4 tag');
  }
  final tagSize =
      (source[6] << 21) | (source[7] << 14) | (source[8] << 7) | source[9];
  final tagEnd = 10 + tagSize;
  if (tagEnd > source.length) {
    throw const FormatException('Truncated AAC ID3 tag');
  }

  final frames = <int>[];
  var offset = 10;
  while (offset + 10 <= tagEnd) {
    final id = ascii.decode(source.sublist(offset, offset + 4));
    if (id == '\u0000\u0000\u0000\u0000') break;
    final size =
        (source[offset + 4] << 21) |
        (source[offset + 5] << 14) |
        (source[offset + 6] << 7) |
        source[offset + 7];
    final end = offset + 10 + size;
    if (end > tagEnd) {
      throw const FormatException('Malformed AAC ID3 frame');
    }
    if (id != 'USLT') frames.addAll(source.sublist(offset, end));
    offset = end;
  }

  if (lyrics.trim().isNotEmpty) {
    final payload = <int>[3, ...ascii.encode('eng'), 0, ...utf8.encode(lyrics)];
    frames.addAll([
      ...ascii.encode('USLT'),
      ..._syncSafe32(payload.length),
      0,
      0,
      ...payload,
    ]);
  }

  final tag = <int>[
    ...source.sublist(0, 6),
    ..._syncSafe32(frames.length),
    ...frames,
  ];
  await _replaceFileAtomically(file, [...tag, ...source.sublist(tagEnd)]);
}

Future<void> _replaceFileAtomically(File file, List<int> contents) async {
  final suffix = '.neonamp-${DateTime.now().microsecondsSinceEpoch}';
  final temporary = File('${file.path}$suffix.tmp');
  final backup = File('${file.path}$suffix.bak');
  var movedOriginal = false;
  try {
    await temporary.writeAsBytes(contents, flush: true);
    await file.rename(backup.path);
    movedOriginal = true;
    await temporary.rename(file.path);
    await backup.delete();
  } catch (error) {
    if (movedOriginal && !await file.exists() && await backup.exists()) {
      try {
        await backup.rename(file.path);
      } on Object catch (restoreError) {
        throw StateError(
          'Could not restore ${file.path} after metadata write failed: '
          '$restoreError (original error: $error)',
        );
      }
    }
    rethrow;
  } finally {
    if (await temporary.exists()) {
      try {
        await temporary.delete();
      } on Object {
        // A failed cleanup must not hide the metadata write result.
      }
    }
  }
}

void _updateCommonTrackMetadata(File file, List<String> values) {
  updateMetadata(file, (metadata) {
    metadata.setTitle(values[0]);
    metadata.setArtist(values[1]);
    metadata.setAlbum(values[2]);
    metadata.setGenres([values[3]]);
    final parsedYear = int.tryParse(values[5]);
    final parsedTrack = int.tryParse(values[6]);
    final parsedTrackTotal = int.tryParse(values[7]);
    final parsedDisc = int.tryParse(values[8]);
    final parsedDiscTotal = int.tryParse(values[9]);
    metadata.setYear(parsedYear == null ? null : DateTime(parsedYear));
    metadata.setTrackNumber(parsedTrack);
    metadata.setTrackTotal(parsedTrackTotal);
    metadata.setCD(parsedDisc, parsedDiscTotal);
    metadata.setLyrics(values[10].trim().isEmpty ? null : values[10]);
  });
}

({int id, int dataStart, int end, bool unknown}) _readEbmlElement(
  Uint8List data,
  int offset,
  int parentEnd,
) {
  int readVint(bool isId) {
    if (offset >= parentEnd) throw const FormatException('Truncated EBML');
    final first = data[offset];
    var marker = 0x80;
    var width = 1;
    while (width <= 8 && first & marker == 0) {
      marker >>= 1;
      width++;
    }
    if (width > 8 || (isId && width > 4) || offset + width > parentEnd) {
      throw const FormatException('Invalid EBML variable integer');
    }
    var value = isId ? first : first & (marker - 1);
    for (var index = 1; index < width; index++) {
      value = (value << 8) | data[offset + index];
    }
    offset += width;
    if (isId && value == 0) throw const FormatException('Invalid EBML ID');
    if (!isId && value == (1 << (7 * width)) - 1) return -1;
    return value;
  }

  final id = readVint(true);
  final encodedSize = readVint(false);
  final unknown = encodedSize == -1;
  final end = unknown ? parentEnd : offset + encodedSize;
  if (end < offset || end > parentEnd) {
    throw const FormatException('EBML element exceeds its parent');
  }
  return (id: id, dataStart: offset, end: end, unknown: unknown);
}

List<int> _encodeEbmlSize(int size) {
  if (size < 0) throw const FormatException('Negative EBML element size');
  var width = 1;
  while (width <= 8 && size >= (1 << (7 * width)) - 1) {
    width++;
  }
  if (width > 8) throw const FormatException('EBML element is too large');
  final bytes = List<int>.filled(width, 0);
  var remainder = size;
  for (var index = width - 1; index >= 0; index--) {
    bytes[index] = remainder & 0xff;
    remainder >>= 8;
  }
  bytes[0] |= 1 << (8 - width);
  return bytes;
}

List<int> _encodeEbmlElement(int id, List<int> payload) {
  var idWidth = 1;
  while (idWidth < 4 && id >= (1 << (idWidth * 8))) {
    idWidth++;
  }
  final idBytes = List<int>.generate(
    idWidth,
    (index) => (id >> ((idWidth - index - 1) * 8)) & 0xff,
  );
  return [...idBytes, ..._encodeEbmlSize(payload.length), ...payload];
}

const _managedMatroskaTagNames = {
  'TITLE',
  'ARTIST',
  'ALBUM',
  'GENRE',
  'DATE',
  'DATE_RELEASED',
  'RELEASE_DATE',
  'TRACKNUMBER',
  'TRACK',
  'PART_NUMBER',
  'TRACKTOTAL',
  'TOTAL_TRACKS',
  'DISCNUMBER',
  'DISC',
  'DISCTOTAL',
  'TOTAL_DISCS',
  'LYRICS',
};

String? _matroskaSimpleTagName(Uint8List data, int start, int end) {
  var offset = start;
  while (offset < end) {
    final child = _readEbmlElement(data, offset, end);
    if (child.id == 0x45a3) {
      return utf8.decode(
        data.sublist(child.dataStart, child.end),
        allowMalformed: true,
      );
    }
    offset = child.end;
  }
  return null;
}

List<int> _matroskaSimpleTag(String name, String value) =>
    _encodeEbmlElement(0x67c8, [
      ..._encodeEbmlElement(0x45a3, utf8.encode(name)),
      ..._encodeEbmlElement(0x4487, utf8.encode(value)),
    ]);

List<int> _matroskaManagedTags(List<String> values) {
  final tags = <int>[];
  void add(String name, String value) {
    if (value.trim().isNotEmpty) tags.addAll(_matroskaSimpleTag(name, value));
  }

  add('TITLE', values[0]);
  add('ARTIST', values[1]);
  add('ALBUM', values[2]);
  add('GENRE', values[3]);
  add('DATE_RELEASED', values[5]);
  add('TRACKNUMBER', values[6]);
  add('TRACKTOTAL', values[7]);
  add('DISCNUMBER', values[8]);
  add('DISCTOTAL', values[9]);
  add('LYRICS', values[10]);
  return tags;
}

({List<int> bytes, bool changed, bool hadManaged}) _rewriteMatroskaTag(
  Uint8List data,
  int start,
  int end,
  List<int> replacementTags,
  bool insertReplacement,
) {
  final element = _readEbmlElement(data, start, end);
  final children = <int>[];
  var offset = element.dataStart;
  var hadManaged = false;
  var changed = false;
  while (offset < element.end) {
    final child = _readEbmlElement(data, offset, element.end);
    final isManaged =
        child.id == 0x67c8 &&
        _managedMatroskaTagNames.contains(
          _matroskaSimpleTagName(
            data,
            child.dataStart,
            child.end,
          )?.toUpperCase(),
        );
    if (isManaged) {
      hadManaged = true;
      changed = true;
    } else {
      children.addAll(data.sublist(offset, child.end));
    }
    offset = child.end;
  }
  if (hadManaged && insertReplacement) children.addAll(replacementTags);
  if (!changed) {
    return (
      bytes: data.sublist(start, element.end),
      changed: false,
      hadManaged: false,
    );
  }
  return (
    bytes: _encodeEbmlElement(element.id, children),
    changed: true,
    hadManaged: hadManaged,
  );
}

Future<void> writeMatroskaTags(File file, List<String> values) async {
  final source = Uint8List.fromList(await file.readAsBytes());
  final ebml = _readEbmlElement(source, 0, source.length);
  if (ebml.id != 0x1a45dfa3) {
    throw const FormatException('Not an EBML WebM/Matroska file');
  }
  final segmentOffset = ebml.end;
  final segment = _readEbmlElement(source, segmentOffset, source.length);
  if (segment.id != 0x18538067) {
    throw const FormatException('Missing Matroska Segment');
  }

  final replacementTags = _matroskaManagedTags(values);
  final retainedTags = <int>[];
  final beforeTags = <int>[];
  final afterTags = <int>[];
  var hasTagsElement = false;
  var hasManagedTag = false;
  var replacementInserted = false;
  var offset = segment.dataStart;
  var stoppedAtOpaqueTail = false;
  while (offset < segment.end) {
    final child = _readEbmlElement(source, offset, segment.end);
    if (child.id == 0x1f43b675 || child.unknown) {
      afterTags.addAll(source.sublist(offset, segment.end));
      stoppedAtOpaqueTail = true;
      break;
    }
    if (child.id == 0x1254c367) {
      hasTagsElement = true;
      final tags = _readEbmlElement(source, offset, segment.end);
      var tagOffset = tags.dataStart;
      while (tagOffset < tags.end) {
        final tag = _readEbmlElement(source, tagOffset, tags.end);
        if (tag.id == 0x7373) {
          final rewritten = _rewriteMatroskaTag(
            source,
            tagOffset,
            tags.end,
            replacementTags,
            !replacementInserted,
          );
          retainedTags.addAll(rewritten.bytes);
          if (rewritten.hadManaged) {
            hasManagedTag = true;
            replacementInserted = true;
          }
        } else {
          retainedTags.addAll(source.sublist(tagOffset, tag.end));
        }
        tagOffset = tag.end;
      }
      if (!replacementInserted && replacementTags.isNotEmpty) {
        retainedTags.addAll(_encodeEbmlElement(0x7373, replacementTags));
        replacementInserted = true;
      }
      offset = child.end;
      continue;
    }
    (hasTagsElement ? afterTags : beforeTags).addAll(
      source.sublist(offset, child.end),
    );
    offset = child.end;
  }
  if (!stoppedAtOpaqueTail && offset < segment.end) {
    afterTags.addAll(source.sublist(offset, segment.end));
  }
  if (!hasTagsElement && replacementTags.isNotEmpty) {
    retainedTags.addAll(_encodeEbmlElement(0x7373, replacementTags));
  } else if (hasTagsElement && !hasManagedTag && replacementTags.isNotEmpty) {
    retainedTags.addAll(_encodeEbmlElement(0x7373, replacementTags));
  }

  final tagsElement = hasTagsElement || replacementTags.isNotEmpty
      ? _encodeEbmlElement(0x1254c367, retainedTags)
      : <int>[];
  final segmentPayload = [...beforeTags, ...tagsElement, ...afterTags];
  final segmentIdWidth = segment.id <= 0xff
      ? 1
      : segment.id <= 0xffff
      ? 2
      : segment.id <= 0xffffff
      ? 3
      : 4;
  final segmentId = source.sublist(
    segmentOffset,
    segmentOffset + segmentIdWidth,
  );
  final segmentHeader = segment.unknown
      ? source.sublist(segmentOffset, segment.dataStart)
      : [...segmentId, ..._encodeEbmlSize(segmentPayload.length)];
  await _replaceFileAtomically(file, [
    ...source.sublist(0, segmentOffset),
    ...segmentHeader,
    ...segmentPayload,
    ...source.sublist(segment.end),
  ]);
}

Future<void> writeTrackMetadata(File file, List<String> values) async {
  if (isMatroskaAudioPath(file.path)) {
    await writeMatroskaTags(file, values);
    return;
  }
  if (isAacAudioPath(file.path)) {
    await writeAacTags(file, values);
    return;
  }
  if (isAsfAudioPath(file.path)) {
    await writeAsfTags(file, values);
    return;
  }
  if (isWavAudioPath(file.path)) {
    await writeWavTags(file, values);
    return;
  }
  if (isAiffAudioPath(file.path)) {
    await writeAiffTags(file, values);
    return;
  }
  if (isVorbisAudioPath(file.path)) {
    await writeVorbisTags(file, values);
    return;
  }
  _updateCommonTrackMetadata(file, values);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NeonAmpApp());
}

String? _replayGainField(Map<String, String> fields, String name) {
  for (final entry in fields.entries) {
    if (entry.key.toUpperCase() == name) return entry.value;
  }
  return null;
}

double? replayGainDbFromMetadata(Object metadata) {
  String? trackGain;
  String? albumGain;
  switch (metadata) {
    case VorbisMetadata value:
      trackGain = value.replayGainTrackGain.firstOrNull;
      albumGain = value.replayGainAlbumGain.firstOrNull;
      break;
    case Mp3Metadata value:
      trackGain = _replayGainField(
        value.customMetadata,
        'REPLAYGAIN_TRACK_GAIN',
      );
      albumGain = _replayGainField(
        value.customMetadata,
        'REPLAYGAIN_ALBUM_GAIN',
      );
      break;
    case ApeMetadata value:
      trackGain = _replayGainField(value.unknowns, 'REPLAYGAIN_TRACK_GAIN');
      albumGain = _replayGainField(value.unknowns, 'REPLAYGAIN_ALBUM_GAIN');
      break;
    case RiffMetadata value:
      trackGain = _replayGainField(value.unknowns, 'REPLAYGAIN_TRACK_GAIN');
      albumGain = _replayGainField(value.unknowns, 'REPLAYGAIN_ALBUM_GAIN');
      break;
    default:
      return null;
  }
  return parseReplayGainDb(trackGain) ?? parseReplayGainDb(albumGain);
}

double? readReplayGainDb(File file) {
  try {
    if (isAsfAudioPath(file.path)) {
      final fields = readAsfFieldsFromFile(file);
      String? field(String name) {
        for (final entry in fields.entries) {
          if (entry.key.toUpperCase() == name) return entry.value;
        }
        return null;
      }

      return parseReplayGainDb(field('REPLAYGAIN_TRACK_GAIN')) ??
          parseReplayGainDb(field('REPLAYGAIN_ALBUM_GAIN'));
    }
    return replayGainDbFromMetadata(readAllMetadata(file, getImage: false));
  } on Object {
    return null;
  }
}

Map<String, dynamic> normalizeShoutcastStation(Map<String, dynamic> station) =>
    {
      'name': station['Name'] as String? ?? 'SHOUTcast station',
      'genre': station['Genre'] as String? ?? 'Radio',
      'listeners': station['Listeners'] as num? ?? 0,
      'bitrate': station['Bitrate'] as num? ?? 0,
      'codec': station['Format'] as String? ?? '',
      'country': 'SHOUTcast',
      'source': 'SHOUTcast',
      'shoutcastId': station['ID'],
      'streamUrl': station['StreamUrl'] as String?,
    };

Map<String, dynamic> normalizeRadioBrowserStation(
  Map<String, dynamic> station,
) => {
  'name': station['name'] as String? ?? 'Radio Browser station',
  'genre': station['tags'] as String? ?? 'Radio',
  'listeners': station['votes'] as num? ?? 0,
  'bitrate': station['bitrate'] as num? ?? 0,
  'codec': station['codec'] as String? ?? '',
  'country': station['country'] as String? ?? '',
  'source': 'Radio Browser',
  'url_resolved': station['url_resolved'] as String?,
  'url': station['url'] as String?,
};

List<Map<String, dynamic>> mergeRadioStations(
  Iterable<Map<String, dynamic>> stations,
) {
  final merged = <String, Map<String, dynamic>>{};
  final unresolved = <Map<String, dynamic>>[];
  for (final station in stations) {
    final resolved =
        station['streamUrl'] ?? station['url_resolved'] ?? station['url'];
    final key = resolved is String ? resolved.trim().toLowerCase() : '';
    if (key.isEmpty) {
      unresolved.add(station);
      continue;
    }
    final existing = merged[key];
    if (existing == null ||
        ((station['listeners'] as num?)?.toInt() ?? 0) >
            ((existing['listeners'] as num?)?.toInt() ?? 0)) {
      merged[key] = station;
    }
  }
  final result = [...merged.values, ...unresolved];
  result.sort(
    (a, b) => ((b['listeners'] as num?)?.toInt() ?? 0).compareTo(
      (a['listeners'] as num?)?.toInt() ?? 0,
    ),
  );
  return result;
}

class NeonAmpPlugin {
  const NeonAmpPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.capabilities,
    required this.equalizerPresets,
    this.enabled = true,
  });

  factory NeonAmpPlugin.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? '';
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(id) || name.isEmpty) {
      throw const FormatException('Plugin id and name are required.');
    }
    final rawPresets = json['equalizerPresets'];
    final equalizerPresets = <String, List<double>>{};
    if (rawPresets is Map) {
      for (final entry in rawPresets.entries) {
        final presetName = entry.key.toString().trim();
        final values = entry.value;
        if (presetName.isEmpty || values is! List || values.length != 10) {
          throw const FormatException(
            'Equalizer presets must contain exactly 10 bands.',
          );
        }
        if (values.any((value) => value is! num)) {
          throw const FormatException('Equalizer bands must be numeric.');
        }
        final bands = values.map((value) => (value as num).toDouble()).toList();
        if (bands.any((value) => value < -12 || value > 12)) {
          throw const FormatException(
            'Equalizer bands must be between -12 and 12 dB.',
          );
        }
        equalizerPresets[presetName] = bands;
      }
    }
    return NeonAmpPlugin(
      id: id,
      name: name,
      version: (json['version'] as String?)?.trim().isNotEmpty == true
          ? (json['version'] as String).trim()
          : '1.0.0',
      description: (json['description'] as String?)?.trim() ?? '',
      capabilities:
          (json['capabilities'] as List?)
              ?.whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList() ??
          const [],
      equalizerPresets: equalizerPresets,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  final String id;
  final String name;
  final String version;
  final String description;
  final List<String> capabilities;
  final Map<String, List<double>> equalizerPresets;
  final bool enabled;

  NeonAmpPlugin copyWith({bool? enabled}) => NeonAmpPlugin(
    id: id,
    name: name,
    version: version,
    description: description,
    capabilities: capabilities,
    equalizerPresets: equalizerPresets,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'description': description,
    'capabilities': capabilities,
    'equalizerPresets': equalizerPresets,
    'enabled': enabled,
  };
}

String syncFileName(String path) {
  final base = path.split(RegExp(r'[/\\]')).last.trim();
  final safe = base.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  return safe.isEmpty ? 'track' : safe;
}

String nextSyncFileName(String requested, Set<String> usedNames) {
  final dot = requested.lastIndexOf('.');
  final stem = dot > 0 ? requested.substring(0, dot) : requested;
  final extension = dot > 0 ? requested.substring(dot) : '';
  var candidate = requested;
  var suffix = 2;
  while (usedNames.contains(candidate.toLowerCase())) {
    candidate = '$stem ($suffix)$extension';
    suffix++;
  }
  usedNames.add(candidate.toLowerCase());
  return candidate;
}

String convertedM4aFileName(String path) {
  final name = syncFileName(path);
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return '$stem.m4a';
}

Duration? sleepTimerRemaining(DateTime? deadline, DateTime now) {
  if (deadline == null) return null;
  final remaining = deadline.difference(now);
  return remaining.isNegative ? Duration.zero : remaining;
}

List<String> addToPlayHistory(
  List<String> history,
  String path, {
  int maxEntries = 50,
}) {
  final next = <String>[path, ...history.where((item) => item != path)];
  return next.length > maxEntries ? next.sublist(0, maxEntries) : next;
}

Duration? restoreResumePosition(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 3000) return null;
  return Duration(milliseconds: milliseconds);
}

Duration seekByOffset({
  required Duration position,
  required Duration duration,
  required Duration offset,
}) {
  final target = position + offset;
  if (target < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && target > duration) return duration;
  return target;
}

List<Track> toggleTrackBookmark(List<Track> bookmarks, Track track) {
  if (bookmarks.any((item) => item.identityKey == track.identityKey)) {
    return bookmarks
        .where((item) => item.identityKey != track.identityKey)
        .toList();
  }
  return [...bookmarks, track];
}

class Track {
  Track({
    required this.path,
    required this.name,
    this.artist = 'Local library',
    this.album = 'Unknown album',
    this.genre = 'Unknown genre',
    this.year,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.discTotal,
    this.lyrics,
    this.rating = 0,
    this.playCount = 0,
    this.favorite = false,
    this.artwork,
    this.replayGainDb,
    this.cueStartMs,
    this.cueEndMs,
  });
  final String path;
  final String name;
  final String artist;
  final String album;
  final String genre;
  final int? year;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final int? discTotal;
  final String? lyrics;
  final int rating;
  final int playCount;
  final bool favorite;
  final Uint8List? artwork;
  final double? replayGainDb;
  final int? cueStartMs;
  final int? cueEndMs;

  Duration get cueStart => Duration(milliseconds: cueStartMs ?? 0);
  Duration? get cueEnd =>
      cueEndMs == null ? null : Duration(milliseconds: cueEndMs!);
  String get identityKey => cueStartMs == null
      ? path
      : jsonEncode([path, cueStartMs, cueEndMs, trackNumber]);

  Track copyWith({
    String? path,
    String? name,
    String? artist,
    String? album,
    String? genre,
    int? year,
    int? trackNumber,
    int? trackTotal,
    int? discNumber,
    int? discTotal,
    String? lyrics,
    int? rating,
    int? playCount,
    bool? favorite,
    Uint8List? artwork,
    double? replayGainDb,
    int? cueStartMs,
    int? cueEndMs,
    bool clearLyrics = false,
  }) => Track(
    path: path ?? this.path,
    name: name ?? this.name,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    genre: genre ?? this.genre,
    year: year ?? this.year,
    trackNumber: trackNumber ?? this.trackNumber,
    trackTotal: trackTotal ?? this.trackTotal,
    discNumber: discNumber ?? this.discNumber,
    discTotal: discTotal ?? this.discTotal,
    lyrics: clearLyrics ? null : lyrics ?? this.lyrics,
    rating: rating ?? this.rating,
    playCount: playCount ?? this.playCount,
    favorite: favorite ?? this.favorite,
    artwork: artwork ?? this.artwork,
    replayGainDb: replayGainDb ?? this.replayGainDb,
    cueStartMs: cueStartMs ?? this.cueStartMs,
    cueEndMs: cueEndMs ?? this.cueEndMs,
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'artist': artist,
    'album': album,
    'genre': genre,
    if (year != null) 'year': year,
    if (trackNumber != null) 'trackNumber': trackNumber,
    if (trackTotal != null) 'trackTotal': trackTotal,
    if (discNumber != null) 'discNumber': discNumber,
    if (discTotal != null) 'discTotal': discTotal,
    if (lyrics != null) 'lyrics': lyrics,
    'rating': rating,
    'playCount': playCount,
    'favorite': favorite,
    if (artwork != null) 'artwork': base64Encode(artwork!),
    if (replayGainDb != null) 'replayGainDb': replayGainDb,
    if (cueStartMs != null) 'cueStartMs': cueStartMs,
    if (cueEndMs != null) 'cueEndMs': cueEndMs,
  };

  static Track fromJson(Map<String, dynamic> json) => Track(
    path: json['path'] as String,
    name: json['name'] as String,
    artist: json['artist'] as String? ?? 'Local library',
    album: json['album'] as String? ?? 'Unknown album',
    genre: json['genre'] as String? ?? 'Unknown genre',
    year: (json['year'] as num?)?.toInt(),
    trackNumber: (json['trackNumber'] as num?)?.toInt(),
    trackTotal: (json['trackTotal'] as num?)?.toInt(),
    discNumber: (json['discNumber'] as num?)?.toInt(),
    discTotal: (json['discTotal'] as num?)?.toInt(),
    lyrics: json['lyrics'] as String?,
    rating: (json['rating'] as num?)?.toInt() ?? 0,
    playCount: (json['playCount'] as num?)?.toInt() ?? 0,
    favorite: json['favorite'] as bool? ?? false,
    artwork: json['artwork'] is String
        ? base64Decode(json['artwork'] as String)
        : null,
    replayGainDb: (json['replayGainDb'] as num?)?.toDouble(),
    cueStartMs: (json['cueStartMs'] as num?)?.toInt(),
    cueEndMs: (json['cueEndMs'] as num?)?.toInt(),
  );
}

Duration _cueRelativePosition(Track? track, Duration sourcePosition) {
  return cueRelativePosition(sourcePosition, track?.cueStart ?? Duration.zero);
}

Duration _cueRelativeDuration(Track? track, Duration sourceDuration) {
  return cueSegmentDuration(
    sourceDuration,
    start: track?.cueStart ?? Duration.zero,
    end: track?.cueEnd,
  );
}

class ThemeSkin {
  const ThemeSkin({
    required this.name,
    required this.seedColor,
    required this.backgroundColor,
  });

  final String name;
  final Color seedColor;
  final Color backgroundColor;

  Map<String, dynamic> toJson() => {
    'name': name,
    'seedColor': _colorToHex(seedColor),
    'backgroundColor': _colorToHex(backgroundColor),
  };

  static ThemeSkin fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?)?.trim() ?? '';
    if (name.isEmpty || name.length > 40) {
      throw const FormatException(
        'Skin name must be between 1 and 40 characters.',
      );
    }
    return ThemeSkin(
      name: name,
      seedColor: _colorFromJson(json['seedColor'], 'seedColor'),
      backgroundColor: _colorFromJson(
        json['backgroundColor'],
        'backgroundColor',
      ),
    );
  }
}

String _colorToHex(Color color) =>
    '#${color.value.toRadixString(16).padLeft(8, '0').substring(2)}';

Color _colorFromJson(Object? value, String field) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    throw FormatException('$field must be a six-digit hex color.');
  }
  return Color(int.parse('ff${value.substring(1)}', radix: 16));
}

List<ThemeSkin> builtInSkins() => const [
  ThemeSkin(
    name: 'Neon',
    seedColor: Color(0xffef4bff),
    backgroundColor: Color(0xff090a10),
  ),
  ThemeSkin(
    name: 'Aurora',
    seedColor: Color(0xff35e6ff),
    backgroundColor: Color(0xff071015),
  ),
  ThemeSkin(
    name: 'Amber',
    seedColor: Color(0xffffa62b),
    backgroundColor: Color(0xff120d07),
  ),
  ThemeSkin(
    name: 'Classic',
    seedColor: Color(0xff7dff55),
    backgroundColor: Color(0xff081008),
  ),
];

class SmartCriterion {
  const SmartCriterion({required this.rule, this.value = ''});

  final String rule;
  final String value;

  Map<String, dynamic> toJson() => {'rule': rule, 'value': value};

  static SmartCriterion fromJson(Map<String, dynamic> json) => SmartCriterion(
    rule: json['rule'] as String? ?? 'Favorites',
    value: json['value'] as String? ?? '',
  );
}

class SmartPlaylist {
  const SmartPlaylist({
    required this.name,
    required this.rule,
    this.value = '',
    this.sortBy = 'Added',
    this.descending = false,
    this.limit = 0,
    this.criteria,
    this.matchAll = true,
  });

  final String name;
  final String rule;
  final String value;
  final String sortBy;
  final bool descending;
  final int limit;
  final List<SmartCriterion>? criteria;
  final bool matchAll;

  List<SmartCriterion> get effectiveCriteria =>
      criteria == null || criteria!.isEmpty
      ? [SmartCriterion(rule: rule, value: value)]
      : criteria!;

  Map<String, dynamic> toJson() => {
    'name': name,
    'rule': rule,
    'value': value,
    'sortBy': sortBy,
    'descending': descending,
    'limit': limit,
    'matchAll': matchAll,
    'criteria': effectiveCriteria
        .map((criterion) => criterion.toJson())
        .toList(),
  };

  static SmartPlaylist fromJson(Map<String, dynamic> json) {
    final rawCriteria = json['criteria'];
    final criteria = rawCriteria is List
        ? rawCriteria
              .whereType<Map>()
              .map(
                (item) =>
                    SmartCriterion.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : null;
    return SmartPlaylist(
      name: json['name'] as String? ?? 'Smart playlist',
      rule: json['rule'] as String? ?? 'Favorites',
      value: json['value'] as String? ?? '',
      sortBy: json['sortBy'] as String? ?? 'Added',
      descending: json['descending'] as bool? ?? false,
      limit: (json['limit'] as num?)?.toInt() ?? 0,
      criteria: criteria,
      matchAll: json['matchAll'] as bool? ?? true,
    );
  }
}

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

class _NextTrackIntent extends Intent {
  const _NextTrackIntent();
}

class _PreviousTrackIntent extends Intent {
  const _PreviousTrackIntent();
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.amount);
  final Duration amount;
}

class _MuteIntent extends Intent {
  const _MuteIntent();
}

class NeonAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  NeonAudioHandler(this.player) {
    _bindPlayerStreams();
  }

  AudioPlayer player;
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;
  Future<void> Function()? onPlayRequested;
  Future<void> Function()? onPauseRequested;
  Future<void> Function()? onStopRequested;
  Future<void> Function(Duration position)? onSeekRequested;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<PlayerState>? _stateSubscription;
  double _playbackSpeed = 1.0;
  Duration _trackStart = Duration.zero;
  Duration? _trackEnd;
  Duration _lastPosition = Duration.zero;
  bool _closed = false;
  int _commandGeneration = 0;

  void _bindPlayerStreams() {
    _positionSubscription = player.onPositionChanged.listen(
      (position) => _broadcast(position: _relativePosition(position)),
    );
    _durationSubscription = player.onDurationChanged.listen((duration) {
      final current = mediaItem.value;
      final trackDuration = _relativeDuration(duration);
      if (current != null) {
        mediaItem.add(current.copyWith(duration: trackDuration));
      }
      _broadcast();
    });
    _stateSubscription = player.onPlayerStateChanged.listen(
      (state) => _broadcast(state: state),
    );
  }

  Future<void> switchPlayer(AudioPlayer nextPlayer) async {
    if (_closed) return;
    final generation = ++_commandGeneration;
    await _positionSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _stateSubscription?.cancel();
    if (_closed || generation != _commandGeneration) return;
    player = nextPlayer;
    _bindPlayerStreams();
    _broadcast();
  }

  Future<void> playTrack(Track track, {double? playbackSpeed}) async {
    if (_closed) return;
    final generation = ++_commandGeneration;
    if (playbackSpeed != null) {
      _playbackSpeed = normalizePlaybackSpeed(playbackSpeed);
    }
    await player.stop();
    if (_closed || generation != _commandGeneration) return;
    _trackStart = track.cueStart;
    _trackEnd = track.cueEnd;
    _lastPosition = Duration.zero;
    final duration = track.cueEnd == null
        ? null
        : track.cueEnd! - track.cueStart;
    mediaItem.add(
      MediaItem(
        id: track.identityKey,
        title: track.name,
        artist: track.artist,
        album: track.album,
        artUri: null,
        duration: duration,
      ),
    );
    await player.play(
      isUriMediaPath(track.path)
          ? UrlSource(track.path)
          : DeviceFileSource(track.path),
    );
    if (_closed || generation != _commandGeneration) {
      return;
    }
    await player.setPlaybackRate(_playbackSpeed);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (_closed) return;
    final generation = ++_commandGeneration;
    _playbackSpeed = normalizePlaybackSpeed(speed);
    await player.setPlaybackRate(_playbackSpeed);
    if (_closed || generation != _commandGeneration) return;
    _broadcast();
  }

  void publishTrack(Track track) {
    if (_closed) return;
    _trackStart = track.cueStart;
    _trackEnd = track.cueEnd;
    _lastPosition = Duration.zero;
    mediaItem.add(
      MediaItem(
        id: track.identityKey,
        title: track.name,
        artist: track.artist,
        album: track.album,
        artUri: null,
      ),
    );
  }

  Duration _relativePosition(Duration source) {
    final relative = source - _trackStart;
    return relative.isNegative ? Duration.zero : relative;
  }

  Duration _relativeDuration(Duration source) {
    final relative = (_trackEnd ?? source) - _trackStart;
    return relative.isNegative ? Duration.zero : relative;
  }

  void syncExternalState({
    Duration? position,
    Duration? duration,
    required PlayerState state,
  }) {
    if (_closed) return;
    final current = mediaItem.value;
    if (current != null && duration != null) {
      mediaItem.add(current.copyWith(duration: duration));
    }
    _broadcast(position: position, state: state);
  }

  @override
  Future<void> play() => _closed
      ? Future<void>.value()
      : onPlayRequested?.call() ?? player.resume();

  @override
  Future<void> pause() => _closed
      ? Future<void>.value()
      : onPauseRequested?.call() ?? player.pause();

  @override
  Future<void> stop() =>
      _closed ? Future<void>.value() : onStopRequested?.call() ?? player.stop();

  @override
  Future<void> seek(Duration position) {
    if (_closed) return Future<void>.value();
    final duration = mediaItem.value?.duration;
    final target = position.isNegative
        ? Duration.zero
        : duration != null && position > duration
        ? duration
        : position;
    return onSeekRequested?.call(target) ?? player.seek(target);
  }

  @override
  Future<void> skipToNext() async {
    if (_closed) return;
    await onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_closed) return;
    await onPrevious?.call();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _positionSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _stateSubscription?.cancel();
    onNext = null;
    onPrevious = null;
    onPlayRequested = null;
    onPauseRequested = null;
    onStopRequested = null;
    onSeekRequested = null;
  }

  void _broadcast({Duration? position, PlayerState? state}) {
    if (_closed) return;
    final currentState = state ?? player.state;
    final duration = mediaItem.value?.duration;
    if (position != null) _lastPosition = position;
    var updatePosition = _lastPosition;
    if (updatePosition.isNegative) updatePosition = Duration.zero;
    if (duration != null && updatePosition > duration)
      updatePosition = duration;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          currentState == PlayerState.playing
              ? MediaControl.pause
              : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: currentState == PlayerState.completed
            ? AudioProcessingState.completed
            : AudioProcessingState.ready,
        playing: currentState == PlayerState.playing,
        updatePosition: updatePosition,
        speed: _playbackSpeed,
      ),
    );
  }
}

class NeonAmpApp extends StatefulWidget {
  const NeonAmpApp({super.key});

  @override
  State<NeonAmpApp> createState() => _NeonAmpAppState();
}

class _NeonAmpAppState extends State<NeonAmpApp> {
  String _themeName = 'Neon';
  final Map<String, ThemeSkin> _customSkins = {};
  int _themeOperationGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final operation = ++_themeOperationGeneration;
    final prefs = await SharedPreferences.getInstance();
    final savedSkins = prefs.getString('customSkins');
    if (savedSkins != null) {
      try {
        final decoded = jsonDecode(savedSkins) as List;
        for (final value in decoded) {
          final skin = ThemeSkin.fromJson(value as Map<String, dynamic>);
          if (builtInSkins().every((builtin) => builtin.name != skin.name)) {
            _customSkins[skin.name] = skin;
          }
        }
      } on Object {
        _customSkins.clear();
      }
    }
    if (!mounted || operation != _themeOperationGeneration) return;
    setState(() => _themeName = prefs.getString('themeName') ?? 'Neon');
  }

  Future<void> _setTheme(String themeName) async {
    final operation = ++_themeOperationGeneration;
    if (!mounted) return;
    setState(() => _themeName = themeName);
    final prefs = await SharedPreferences.getInstance();
    if (operation != _themeOperationGeneration) return;
    await prefs.setString('themeName', themeName);
  }

  Future<void> _addCustomSkin(ThemeSkin skin) async {
    if (!mounted) return;
    final operation = ++_themeOperationGeneration;
    if (builtInSkins().any((builtin) => builtin.name == skin.name)) {
      throw const FormatException('Built-in skin names cannot be replaced.');
    }
    setState(() {
      _customSkins[skin.name] = skin;
      _themeName = skin.name;
    });
    final encodedSkins = jsonEncode(
      _customSkins.values.map((value) => value.toJson()).toList(),
    );
    final prefs = await SharedPreferences.getInstance();
    if (operation != _themeOperationGeneration) return;
    await prefs.setString('customSkins', encodedSkins);
    await prefs.setString('themeName', skin.name);
  }

  List<ThemeSkin> get _skins => [...builtInSkins(), ..._customSkins.values];

  ThemeData _themeData() {
    final skin = _skins.firstWhere(
      (value) => value.name == _themeName,
      orElse: () => builtInSkins().first,
    );
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: skin.backgroundColor,
      colorScheme: ColorScheme.fromSeed(
        seedColor: skin.seedColor,
        brightness: Brightness.dark,
      ),
      fontFamily: 'Segoe UI',
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NeonAmp',
    debugShowCheckedModeBanner: false,
    theme: _themeData(),
    home: PlayerPage(
      themeName: _themeName,
      skins: _skins,
      onThemeChanged: _setTheme,
      onSkinImported: _addCustomSkin,
    ),
  );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    this.themeName = 'Neon',
    this.skins = const [],
    this.onThemeChanged,
    this.onSkinImported,
  });

  final String themeName;
  final List<ThemeSkin> skins;
  final ValueChanged<String>? onThemeChanged;
  final Future<void> Function(ThemeSkin skin)? onSkinImported;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  AudioPlayer _activePlayer = AudioPlayer();
  final DlnaCast _dlnaCast = DlnaCast();
  DspLocalPlayer _dspPlayer = DspLocalPlayer();
  final WindowsMidiPlayer _midiPlayer = WindowsMidiPlayer();
  NeonAudioHandler? _audioHandler;
  final List<Track> _queue = [];
  final List<Track> _library = [];
  final List<Track> _bookmarks = [];
  final List<String> _playHistory = [];
  final Map<String, int> _resumePositions = {};
  final List<String> _libraryFolders = [];
  final Map<String, String> _libraryRelativePaths = {};
  final List<String> _podcastFeeds = [];
  final Map<String, List<String>> _playlists = {};
  final List<SmartPlaylist> _smartPlaylists = [];
  final Map<String, NeonAmpPlugin> _plugins = {};
  final TextEditingController _searchController = TextEditingController();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  )..repeat();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _dspPositionSub;
  StreamSubscription<Duration>? _dspDurationSub;
  StreamSubscription<PlayerState>? _dspStateSub;
  StreamSubscription<void>? _dspCompleteSub;
  StreamSubscription<Duration>? _midiPositionSub;
  StreamSubscription<Duration>? _midiDurationSub;
  StreamSubscription<PlayerState>? _midiStateSub;
  StreamSubscription<void>? _midiCompleteSub;
  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 4, seconds: 12);
  PlayerState _playerState = PlayerState.stopped;
  int _selected = 0;
  double _volume = .82;
  double _balance = 0;
  bool _shuffle = false;
  bool _repeat = false;
  bool _repeatOne = false;
  bool _crossfade = false;
  int _crossfadeSeconds = 3;
  bool _equalizerEnabled = false;
  List<String> _playerControls = List<String>.from(defaultPlayerControls);
  bool _playerLayoutCustomized = false;
  String _activeView = 'queue';
  String _searchQuery = '';
  String _libraryFilter = 'All';
  String _librarySort = 'Added';
  bool _librarySortDescending = false;
  final Set<String> _selectedLibraryPaths = <String>{};
  final List<double> _eqBands = List<double>.filled(10, 0);
  String _eqPreset = 'Flat';
  bool _crossfadeInProgress = false;
  bool _cueTransitioning = false;
  bool _selectionInProgress = false;
  AudioPlayer? _crossfadeAudioPlayer;
  DspLocalPlayer? _crossfadeDspPlayer;
  bool _dspActive = false;
  bool _midiActive = false;
  double _playbackSpeed = 1.0;
  bool _replayGainEnabled = false;
  Timer? _sleepTimer;
  Timer? _resumeSaveTimer;
  bool _saveInProgress = false;
  bool _savePending = false;
  Timer? _castPositionTimer;
  bool _castPositionPollInProgress = false;
  DateTime? _sleepDeadline;
  int _playerStreamGeneration = 0;
  int _dspStreamGeneration = 0;
  int _midiStreamGeneration = 0;
  int _libraryOperationGeneration = 0;
  int _queueOperationGeneration = 0;

  bool get _casting => _dlnaCast.isConnected;

  AudioPlayer get _player => _activePlayer;

  Track? get _current =>
      _queue.isEmpty ? null : _queue[_selected.clamp(0, _queue.length - 1)];
  bool get _isPlaying => _playerState == PlayerState.playing;

  double _volumeFor(Track? track) => playbackVolume(
    volume: _volume,
    replayGainDb: track?.replayGainDb,
    replayGainEnabled: _replayGainEnabled,
  );

  Future<void> _applyCurrentVolume() async {
    final current = _current;
    if (current == null) return;
    final volume = _volumeFor(current);
    if (_casting) {
      await _dlnaCast.setVolume(volume);
    } else if (_dspActive) {
      await _dspPlayer.setVolume(volume);
    } else if (!_midiActive) {
      await _player.setVolume(volume);
    }
  }

  void _applyBalance(double value) {
    final balance = normalizeStereoBalance(value);
    if (_current == null) return;
    if (_dspActive) {
      _dspPlayer.setBalance(balance);
      _crossfadeDspPlayer?.setBalance(balance);
    } else {
      _runAsyncSafely(_player.setBalance(balance), 'Setting balance');
      final incoming = _crossfadeAudioPlayer;
      if (incoming != null) {
        _runAsyncSafely(
          incoming.setBalance(balance),
          'Setting crossfade balance',
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _bindPlayerStreams();
    _bindDspStreams();
    _bindMidiStreams();
    _initializeWindowsMediaKeys();
    _initializeAudioService();
    _loadQueue();
  }

  Future<void> _initializeWindowsMediaKeys() async {
    if (!Platform.isWindows) return;
    const channel = MethodChannel('neonamp/system_controls');
    channel.setMethodCallHandler((call) async {
      if (call.method != 'mediaKey') return null;
      final action = call.arguments;
      if (action is! String || !mounted) return null;
      try {
        switch (action) {
          case 'playPause':
            await _togglePlay();
            break;
          case 'play':
            if (!_isPlaying) await _togglePlay();
            break;
          case 'pause':
            if (_isPlaying) await _pauseCurrent();
            break;
          case 'next':
            await _next();
            break;
          case 'previous':
            await _previous();
            break;
          case 'stop':
            await _stopCurrent();
            break;
        }
      } on Object catch (error) {
        debugPrint('Windows media key action failed: $error');
      }
      return null;
    });
  }

  Future<void> _syncWindowsMediaSession() async {
    if (!Platform.isWindows) return;
    final track = _current;
    if (track == null) return;
    const channel = MethodChannel('neonamp/system_controls');
    try {
      await channel.invokeMethod<void>('setMediaSession', {
        'title': track.name,
        'artist': track.artist,
        'album': track.album,
        'isPlaying': _isPlaying,
        'durationMs': _duration.inMilliseconds,
      });
    } on Object catch (error) {
      debugPrint('Could not update Windows media session: $error');
    }
  }

  void _bindPlayerStreams() {
    final generation = ++_playerStreamGeneration;
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _dspPositionSub?.cancel();
    _dspDurationSub?.cancel();
    _dspStateSub?.cancel();
    _dspCompleteSub?.cancel();
    _positionSub = _player.onPositionChanged.listen((value) {
      if (!mounted ||
          generation != _playerStreamGeneration ||
          _selectionInProgress) {
        return;
      }
      final track = _current;
      final cueEnd = track?.cueEnd;
      if (cueEnd != null && value >= cueEnd && !_cueTransitioning) {
        _cueTransitioning = true;
        _runAsyncSafely(_advanceCueBoundary(), 'Advancing CUE boundary');
        return;
      }
      final relative = _cueRelativePosition(track, value);
      setState(() => _position = relative);
      _rememberResumePosition(relative);
      if (track?.cueStartMs == null &&
          _crossfade &&
          !_crossfadeInProgress &&
          _isPlaying) {
        final remaining = _duration - relative;
        if (remaining <= Duration(seconds: _crossfadeSeconds) &&
            remaining > Duration.zero) {
          _runAsyncSafely(_crossfadeToNext(), 'Starting crossfade');
        }
      }
    });
    _durationSub = _player.onDurationChanged.listen((value) {
      if (!mounted || generation != _playerStreamGeneration) return;
      final duration = _cueRelativeDuration(_current, value);
      setState(() => _duration = duration);
      _audioHandler?.syncExternalState(duration: duration, state: _playerState);
    });
    _stateSub = _player.onPlayerStateChanged.listen((value) {
      if (!mounted || generation != _playerStreamGeneration) return;
      setState(() => _playerState = value);
      _runAsyncSafely(
        _syncWindowsMediaSession(),
        'Updating Windows media session',
      );
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (generation == _playerStreamGeneration &&
          mounted &&
          !_selectionInProgress &&
          !_crossfadeInProgress) {
        _runAsyncSafely(_handleCompletionSafely(), 'Handling track completion');
      }
    });
  }

  void _bindDspStreams() {
    final generation = ++_dspStreamGeneration;
    _dspPositionSub?.cancel();
    _dspDurationSub?.cancel();
    _dspStateSub?.cancel();
    _dspCompleteSub?.cancel();
    _dspPositionSub = _dspPlayer.onPositionChanged.listen((value) {
      if (!mounted ||
          generation != _dspStreamGeneration ||
          !_dspActive ||
          _selectionInProgress) {
        return;
      }
      final track = _current;
      final cueEnd = track?.cueEnd;
      if (cueEnd != null && value >= cueEnd && !_cueTransitioning) {
        _cueTransitioning = true;
        _runAsyncSafely(_advanceCueBoundary(), 'Advancing DSP CUE boundary');
        return;
      }
      final relative = _cueRelativePosition(track, value);
      setState(() => _position = relative);
      _rememberResumePosition(relative);
      if (track?.cueStartMs == null &&
          _crossfade &&
          !_crossfadeInProgress &&
          _isPlaying) {
        final remaining = _duration - relative;
        if (remaining <= Duration(seconds: _crossfadeSeconds) &&
            remaining > Duration.zero) {
          _runAsyncSafely(_crossfadeToNext(), 'Starting DSP crossfade');
        }
      }
      _audioHandler?.syncExternalState(
        position: relative,
        state: PlayerState.playing,
      );
    });
    _dspDurationSub = _dspPlayer.onDurationChanged.listen((value) {
      if (!mounted || generation != _dspStreamGeneration || !_dspActive) {
        return;
      }
      final duration = _cueRelativeDuration(_current, value);
      setState(() => _duration = duration);
      _audioHandler?.syncExternalState(duration: duration, state: _playerState);
    });
    _dspStateSub = _dspPlayer.onPlayerStateChanged.listen((value) {
      if (!mounted || generation != _dspStreamGeneration || !_dspActive) {
        return;
      }
      setState(() => _playerState = value);
      _audioHandler?.syncExternalState(position: _position, state: value);
      _runAsyncSafely(
        _syncWindowsMediaSession(),
        'Updating Windows media session',
      );
    });
    _dspCompleteSub = _dspPlayer.onPlayerComplete.listen((_) {
      if (mounted &&
          generation == _dspStreamGeneration &&
          _dspActive &&
          !_selectionInProgress &&
          !_crossfadeInProgress) {
        _runAsyncSafely(_handleCompletionSafely(), 'Handling DSP completion');
      }
    });
  }

  void _bindMidiStreams() {
    final generation = ++_midiStreamGeneration;
    _midiPositionSub?.cancel();
    _midiDurationSub?.cancel();
    _midiStateSub?.cancel();
    _midiCompleteSub?.cancel();
    _midiPositionSub = _midiPlayer.onPositionChanged.listen((value) {
      if (!mounted ||
          generation != _midiStreamGeneration ||
          !_midiActive ||
          _selectionInProgress) {
        return;
      }
      setState(() => _position = value);
      _rememberResumePosition(value);
      _audioHandler?.syncExternalState(position: value, state: _playerState);
    });
    _midiDurationSub = _midiPlayer.onDurationChanged.listen((value) {
      if (!mounted || generation != _midiStreamGeneration || !_midiActive) {
        return;
      }
      setState(() => _duration = value);
      _runAsyncSafely(
        _syncWindowsMediaSession(),
        'Updating Windows media session',
      );
    });
    _midiStateSub = _midiPlayer.onPlayerStateChanged.listen((value) {
      if (!mounted || generation != _midiStreamGeneration || !_midiActive) {
        return;
      }
      setState(() => _playerState = value);
      _audioHandler?.syncExternalState(position: _position, state: value);
      _runAsyncSafely(
        _syncWindowsMediaSession(),
        'Updating Windows media session',
      );
    });
    _midiCompleteSub = _midiPlayer.onPlayerComplete.listen((_) {
      if (mounted &&
          generation == _midiStreamGeneration &&
          _midiActive &&
          !_selectionInProgress &&
          !_crossfadeInProgress) {
        _runAsyncSafely(_handleCompletionSafely(), 'Handling MIDI completion');
      }
    });
  }

  Future<void> _initializeAudioService() async {
    if (!Platform.isAndroid) return;
    try {
      _audioHandler = await AudioService.init(
        builder: () => NeonAudioHandler(_player),
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.neonamp.audio',
          androidNotificationChannelName: 'NeonAmp playback',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
        ),
      );
      if (!mounted) {
        await _audioHandler?.close();
        _audioHandler = null;
        return;
      }
    } on Object catch (error) {
      debugPrint('Android audio service unavailable: $error');
      return;
    }
    _audioHandler!.onNext = _next;
    _audioHandler!.onPrevious = _previous;
    _audioHandler!.onPlayRequested = _playCurrent;
    _audioHandler!.onPauseRequested = _pauseCurrent;
    _audioHandler!.onStopRequested = _stopCurrent;
    _audioHandler!.onSeekRequested = _seekCurrent;
  }

  Future<void> _showCastDevices() async {
    if (_casting) {
      final stop = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Casting to ${_dlnaCast.rendererName ?? 'device'}'),
          content: const Text('Audio is playing on your network device.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep playing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Stop casting'),
            ),
          ],
        ),
      );
      if (stop == true) {
        _castPositionTimer?.cancel();
        await _dlnaCast.stop();
        if (mounted) {
          setState(() {
            _playerState = PlayerState.stopped;
            _position = Duration.zero;
          });
        }
        _audioHandler?.syncExternalState(
          position: Duration.zero,
          state: PlayerState.stopped,
        );
      }
      return;
    }
    List<MediaRenderer> devices = [];
    var scanning = true;
    var scanStarted = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) {
          Future<void> scan() async {
            if (scanStarted) return;
            scanStarted = true;
            if (!dialogContext.mounted) return;
            updateDialog(() {
              scanning = true;
              error = null;
            });
            try {
              devices = await _dlnaCast.discover();
            } catch (e) {
              error = 'Could not scan the local network: $e';
            } finally {
              scanning = false;
              scanStarted = false;
              if (dialogContext.mounted) updateDialog(() {});
            }
          }

          if (scanning && devices.isEmpty && error == null && !scanStarted) {
            scanStarted = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              scanStarted = false;
              if (dialogContext.mounted) scan();
            });
          }
          return AlertDialog(
            title: const Text('Cast to a device'),
            content: SizedBox(
              width: 360,
              child: scanning
                  ? const Row(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(width: 16),
                        Text('Searching your network…'),
                      ],
                    )
                  : error != null
                  ? Text(error!)
                  : devices.isEmpty
                  ? const Text(
                      'No DLNA/UPnP players found. Make sure your device is on the same Wi-Fi network.',
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: devices
                          .map(
                            (device) => ListTile(
                              leading: const Icon(Icons.speaker_rounded),
                              title: Text(
                                device.description?.friendlyName ??
                                    'Network player',
                              ),
                              subtitle: Text(
                                device.avTransport == null
                                    ? 'Playback not supported'
                                    : 'DLNA / UPnP',
                              ),
                              enabled: device.avTransport != null,
                              onTap: () async {
                                final track = _current;
                                if (track == null) return;
                                final identity = track.identityKey;
                                if (isMidiFilePath(track.path)) {
                                  ScaffoldMessenger.of(this.context)
                                      .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'MIDI/KAR casting is not supported yet.',
                                          ),
                                        ),
                                      );
                                  return;
                                }
                                Navigator.pop(dialogContext);
                                try {
                                  await _dlnaCast.play(
                                    renderer: device,
                                    path: track.path,
                                    title: track.name,
                                    artist: track.artist,
                                    album: track.album,
                                    duration: track.cueStart + _duration,
                                    segmentStart: track.cueStart,
                                    segmentEnd: track.cueEnd,
                                  );
                                  if (!mounted ||
                                      identity != _current?.identityKey) {
                                    await _dlnaCast.stop();
                                    return;
                                  }
                                  if (_dspActive) {
                                    await _dspPlayer.pause();
                                  } else if (_midiActive) {
                                    await _midiPlayer.pause();
                                  } else {
                                    await _player.pause();
                                  }
                                  if (mounted) {
                                    setState(
                                      () => _playerState = PlayerState.playing,
                                    );
                                    _startCastPositionPolling();
                                  }
                                } catch (e) {
                                  if (mounted)
                                    ScaffoldMessenger.of(this.context)
                                        .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Could not start casting: $e',
                                            ),
                                          ),
                                        );
                                }
                              },
                            ),
                          )
                          .toList(),
                    ),
            ),
            actions: [
              if (!scanning)
                TextButton(onPressed: scan, child: const Text('Scan again')),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _playCurrent() async {
    if (_current == null) return;
    final identity = _current!.identityKey;
    if (_casting) {
      await _dlnaCast.resume();
      if (mounted && identity == _current?.identityKey) {
        setState(() => _playerState = PlayerState.playing);
      }
      return;
    }
    if (_playerState == PlayerState.stopped ||
        _playerState == PlayerState.completed) {
      await _select(_selected);
      return;
    }
    if (_midiActive) {
      await _midiPlayer.resume();
    } else if (_dspActive) {
      await _dspPlayer.resume();
    } else {
      await _player.resume();
    }
  }

  Future<void> _pauseCurrent() async {
    final identity = _current?.identityKey;
    if (_casting) {
      await _dlnaCast.pause();
      if (mounted && identity == _current?.identityKey) {
        setState(() => _playerState = PlayerState.paused);
      }
      return;
    }
    if (_midiActive) {
      await _midiPlayer.pause();
    } else if (_dspActive) {
      await _dspPlayer.pause();
    } else {
      await _player.pause();
    }
  }

  Future<void> _stopCurrent() async {
    final identity = _current?.identityKey;
    if (_casting) {
      _castPositionTimer?.cancel();
      await _dlnaCast.stop();
      if (mounted && identity == _current?.identityKey) {
        setState(() {
          _playerState = PlayerState.stopped;
          _position = Duration.zero;
        });
      }
      if (identity == _current?.identityKey) {
        _audioHandler?.syncExternalState(
          position: Duration.zero,
          state: PlayerState.stopped,
        );
      }
      return;
    }
    if (_midiActive) {
      await _midiPlayer.stop();
    } else if (_dspActive) {
      await _dspPlayer.stop();
    } else {
      await _player.stop();
    }
    if (mounted && identity == _current?.identityKey) {
      setState(() => _position = Duration.zero);
    }
  }

  Future<void> _seekCurrent(Duration position) async {
    final identity = _current?.identityKey;
    final clampedPosition = seekByOffset(
      position: Duration.zero,
      duration: _duration,
      offset: position,
    );
    if (_casting) {
      await _dlnaCast.seek(clampedPosition);
      if (mounted && identity == _current?.identityKey) {
        setState(() => _position = clampedPosition);
      }
      return;
    }
    final sourcePosition = _current == null
        ? clampedPosition
        : clampedPosition + _current!.cueStart;
    if (_midiActive) {
      await _midiPlayer.seek(clampedPosition);
    } else if (_dspActive) {
      await _dspPlayer.seek(sourcePosition);
    } else {
      await _player.seek(sourcePosition);
    }
  }

  Future<void> _skipBy(Duration offset) => _seekCurrent(
    seekByOffset(position: _position, duration: _duration, offset: offset),
  );

  Future<void> _setPlaybackSpeed(double speed) async {
    if (_casting) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This network player does not expose speed control.'),
          ),
        );
      }
      return;
    }
    final value = normalizePlaybackSpeed(speed);
    final identity = _current?.identityKey;
    if (!mounted) return;
    setState(() => _playbackSpeed = value);
    if (identity != null && identity == _current?.identityKey) {
      if (_dspActive) {
        await _dspPlayer.setPlaybackSpeed(value);
      } else if (_midiActive) {
        await _midiPlayer.setPlaybackSpeed(value);
      } else {
        await _player.setPlaybackRate(value);
      }
      await _audioHandler?.setPlaybackSpeed(value);
    }
    if (!mounted || identity != _current?.identityKey) return;
    await _saveQueue();
  }

  Future<void> _setEqualizerEnabled(bool enabled) async {
    final wasPlaying = _isPlaying;
    final previousPosition = _position;
    final current = _current;
    final identity = current?.identityKey;
    final needsLocalDsp =
        current != null &&
        !isUriMediaPath(current.path) &&
        !isMidiFilePath(current.path);
    if (!mounted) return;
    setState(() => _equalizerEnabled = enabled);
    if (current != null && (wasPlaying || _dspActive || needsLocalDsp)) {
      await _select(_selected);
      if (mounted && identity == _current?.identityKey) {
        if (previousPosition > Duration.zero) {
          await _seekCurrent(previousPosition);
        }
        if (!wasPlaying) await _pauseCurrent();
      }
    }
    if (!mounted) return;
    await _saveQueue();
    _runAsyncSafely(
      _syncWindowsMediaSession(),
      'Updating Windows media session',
    );
  }

  Future<void> _setReplayGainEnabled(bool enabled) async {
    if (!mounted) return;
    setState(() => _replayGainEnabled = enabled);
    await _applyCurrentVolume();
    if (!mounted) return;
    await _saveQueue();
  }

  Future<void> _handleComplete() async {
    if (_crossfadeInProgress) return;
    final identity = _current?.identityKey;
    if (identity != null) {
      _resumePositions.remove(identity);
      _saveQueueSafely();
    }
    if (_repeatOne) {
      await _seekCurrent(Duration.zero);
      await _playCurrent();
    } else if (_queue.isNotEmpty &&
        (_repeat || _shuffle || _selected < _queue.length - 1)) {
      await _next();
    } else {
      await _stopCurrent();
    }
  }

  void _startCastPositionPolling() {
    _castPositionTimer?.cancel();
    _castPositionTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _runAsyncSafely(_syncCastPosition(), 'Polling cast position'),
    );
  }

  Future<void> _syncCastPosition() async {
    if (!_casting || _castPositionPollInProgress || _selectionInProgress) {
      return;
    }
    _castPositionPollInProgress = true;
    final identity = _current?.identityKey;
    try {
      final position = await _dlnaCast.getPosition();
      if (position == null ||
          !mounted ||
          !_casting ||
          identity != _current?.identityKey)
        return;
      if (_duration > Duration.zero && position >= _duration) {
        _castPositionTimer?.cancel();
        if (_current?.cueStartMs != null && !_cueTransitioning) {
          _cueTransitioning = true;
          await _advanceCueBoundary();
        } else {
          await _handleComplete();
        }
        return;
      }
      setState(() => _position = position);
      _rememberResumePosition(position);
      _audioHandler?.syncExternalState(position: position, state: _playerState);
      _runAsyncSafely(
        _syncWindowsMediaSession(),
        'Updating Windows media session',
      );
    } catch (error) {
      _castPositionTimer?.cancel();
      if (mounted &&
          _casting &&
          identity == _current?.identityKey &&
          !_selectionInProgress) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read cast position: $error')),
        );
      }
    } finally {
      _castPositionPollInProgress = false;
    }
  }

  Future<void> _advanceCueBoundary() async {
    if (_repeatOne) {
      _cueTransitioning = false;
      await _seekCurrent(Duration.zero);
      return;
    }
    if (_queue.isNotEmpty &&
        (_repeat || _shuffle || _selected < _queue.length - 1)) {
      await _next(useCrossfade: false);
    } else {
      await _stopCurrent();
    }
  }

  void _armSleepTimer() {
    _sleepTimer?.cancel();
    final deadline = _sleepDeadline;
    if (deadline == null) return;
    final remaining = sleepTimerRemaining(deadline, DateTime.now())!;
    if (remaining == Duration.zero) {
      _sleepDeadline = null;
      _runAsyncSafely(_stopCurrent(), 'Stopping after sleep timer');
      _saveQueueSafely();
      return;
    }
    _sleepTimer = Timer(remaining, () {
      if (!mounted) return;
      _sleepDeadline = null;
      _runAsyncSafely(_stopCurrent(), 'Stopping after sleep timer');
      _saveQueueSafely();
    });
  }

  Future<void> _setSleepTimer(Duration? duration) async {
    _sleepTimer?.cancel();
    if (!mounted) return;
    setState(
      () => _sleepDeadline = duration == null
          ? null
          : DateTime.now().add(duration),
    );
    _armSleepTimer();
    await _saveQueue();
  }

  Future<void> _showSleepTimer() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Sleep timer'),
        children: [
          if (_sleepDeadline != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 0),
              child: const Text('Turn off timer'),
            ),
          for (final value in [15, 30, 60, 90])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text('$value minutes'),
            ),
        ],
      ),
    );
    if (minutes == null) return;
    await _setSleepTimer(minutes == 0 ? null : Duration(minutes: minutes));
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('queue') ?? [];
    final savedQueueTracks = prefs.getString('queueTracks');
    final savedLibrary = prefs.getStringList('library') ?? [];
    final savedBookmarks = prefs.getString('bookmarks');
    final savedPlayHistory = prefs.getStringList('playHistory') ?? [];
    final savedResumePositions = prefs.getString('resumePositions');
    final savedFolders = prefs.getStringList('libraryFolders') ?? [];
    final savedPodcastFeeds = prefs.getStringList('podcastFeeds') ?? [];
    final savedPlaylists = prefs.getString('playlists');
    final savedSmartPlaylists = prefs.getString('smartPlaylists');
    final savedPlugins = prefs.getString('plugins');
    final savedSettings = prefs.getString('settings');
    if (!mounted) return;
    setState(() {
      for (final value in savedLibrary) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map) {
            final track = Track.fromJson(Map<String, dynamic>.from(decoded));
            if (_library.every((item) => item.path != track.path)) {
              _library.add(track);
            }
          }
        } on Object catch (error) {
          debugPrint('Skipping invalid saved library track: $error');
        }
      }
      if (savedBookmarks != null) {
        try {
          final decoded = jsonDecode(savedBookmarks);
          if (decoded is List) {
            for (final value in decoded) {
              try {
                if (value is Map) {
                  final track = Track.fromJson(
                    Map<String, dynamic>.from(value),
                  );
                  if (_bookmarks.every(
                    (item) => item.identityKey != track.identityKey,
                  )) {
                    _bookmarks.add(track);
                  }
                }
              } on Object catch (error) {
                debugPrint('Skipping invalid saved bookmark: $error');
              }
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved bookmarks: $error');
        }
      }
      if (savedQueueTracks != null) {
        try {
          final decodedQueue = jsonDecode(savedQueueTracks);
          if (decodedQueue is List) {
            for (final value in decodedQueue) {
              try {
                if (value is Map) {
                  final track = Track.fromJson(
                    Map<String, dynamic>.from(value),
                  );
                  if (_queue.every(
                    (item) => item.identityKey != track.identityKey,
                  )) {
                    _queue.add(track);
                  }
                }
              } on Object catch (error) {
                debugPrint('Skipping invalid saved queue track: $error');
              }
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved queue: $error');
        }
      } else {
        _queue.addAll(
          saved.where((path) => path.trim().isNotEmpty).toSet().map((path) {
            return _library.firstWhere(
              (track) => track.path == path,
              orElse: () =>
                  Track(path: path, name: path.split(RegExp(r'[/\\]')).last),
            );
          }),
        );
      }
      _playHistory.addAll(
        savedPlayHistory.where((path) => path.trim().isNotEmpty).toSet(),
      );
      if (savedResumePositions != null) {
        try {
          final decoded = jsonDecode(savedResumePositions);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final position = (entry.value as num?)?.toInt();
              if (position != null && position > 0) {
                _resumePositions[entry.key.toString()] = position;
              }
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved resume positions: $error');
        }
      }
      _libraryFolders.addAll(
        savedFolders.where((folder) => folder.trim().isNotEmpty).toSet(),
      );
      _podcastFeeds.addAll(
        savedPodcastFeeds.where((feed) => feed.trim().isNotEmpty).toSet(),
      );
      if (savedPlaylists != null) {
        try {
          final decoded = jsonDecode(savedPlaylists);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              if (entry.value is List) {
                _playlists[entry.key.toString()] = (entry.value as List)
                    .whereType<String>()
                    .toList();
              }
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved playlists: $error');
        }
      }
      if (savedSmartPlaylists != null) {
        try {
          final decoded = jsonDecode(savedSmartPlaylists);
          if (decoded is List) {
            for (final entry in decoded) {
              try {
                if (entry is Map) {
                  _smartPlaylists.add(
                    SmartPlaylist.fromJson(Map<String, dynamic>.from(entry)),
                  );
                }
              } on Object catch (error) {
                debugPrint('Skipping invalid saved smart playlist: $error');
              }
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved smart playlists: $error');
        }
      }
      if (savedPlugins != null) {
        try {
          final decoded = jsonDecode(savedPlugins);
          if (decoded is List) {
            for (final entry in decoded) {
              try {
                if (entry is Map) {
                  final plugin = NeonAmpPlugin.fromJson(
                    Map<String, dynamic>.from(entry),
                  );
                  _plugins[plugin.id] = plugin;
                }
              } on Object catch (error) {
                debugPrint('Skipping invalid saved plugin: $error');
              }
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved plugins: $error');
        }
      }
      if (savedSettings != null) {
        try {
          final decodedSettings = jsonDecode(savedSettings);
          if (decodedSettings is! Map) {
            throw const FormatException('Saved settings are not an object.');
          }
          final settings = Map<String, dynamic>.from(decodedSettings);
          final savedRelativePaths = settings['libraryRelativePaths'];
          if (savedRelativePaths is Map) {
            _libraryRelativePaths.addAll(
              savedRelativePaths.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              ),
            );
          }
          _volume = ((settings['volume'] as num?)?.toDouble() ?? _volume)
              .clamp(0.0, 1.0)
              .toDouble();
          _balance = normalizeStereoBalance(
            (settings['balance'] as num?)?.toDouble() ?? _balance,
          );
          _crossfade = settings['crossfade'] as bool? ?? false;
          _crossfadeSeconds =
              ((settings['crossfadeSeconds'] as num?)?.toInt() ?? 3)
                  .clamp(1, 12)
                  .toInt();
          _equalizerEnabled = settings['equalizerEnabled'] as bool? ?? false;
          _eqPreset = settings['eqPreset'] as String? ?? 'Flat';
          _playbackSpeed = normalizePlaybackSpeed(
            (settings['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
          );
          _replayGainEnabled = settings['replayGainEnabled'] as bool? ?? false;
          final sleepTimerEnd = (settings['sleepTimerEndMs'] as num?)?.toInt();
          _sleepDeadline = sleepTimerEnd == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(sleepTimerEnd);
          _librarySort = settings['librarySort'] as String? ?? 'Added';
          _librarySortDescending =
              settings['librarySortDescending'] as bool? ?? false;
          final savedPlayerControls = settings['playerControls'];
          if (savedPlayerControls is List) {
            _playerControls = normalizePlayerControls(savedPlayerControls);
            _playerLayoutCustomized = true;
          }
          final savedBands = (settings['eqBands'] as List?)?.cast<num>();
          if (savedBands != null && savedBands.length == _eqBands.length) {
            for (var i = 0; i < _eqBands.length; i++) {
              _eqBands[i] = savedBands[i].toDouble();
            }
          }
        } on Object catch (error) {
          debugPrint('Ignoring invalid saved settings: $error');
        }
      }
    });
    _armSleepTimer();
  }

  Future<void> _saveQueue() async {
    if (_saveInProgress) {
      _savePending = true;
      return;
    }
    _saveInProgress = true;
    try {
      do {
        _savePending = false;
        await _writeQueueSnapshot();
      } while (_savePending);
    } finally {
      _saveInProgress = false;
    }
  }

  void _saveQueueSafely() {
    unawaited(
      _saveQueue().catchError((error, stackTrace) {
        debugPrint('Could not persist NeonAmp state: $error\n$stackTrace');
      }),
    );
  }

  void _runAsyncSafely(Future<void> operation, String description) {
    unawaited(
      operation.catchError((error, stackTrace) {
        debugPrint('$description failed: $error\n$stackTrace');
      }),
    );
  }

  Future<void> _writeQueueSnapshot() async {
    final prefs = await SharedPreferences.getInstance();
    // Freeze the complete state before the first asynchronous write. Without
    // this, a queue/library mutation between individual SharedPreferences
    // writes can persist a mixture of old and new state across app restarts.
    final queueTracks = _queue.map((track) => track.toJson()).toList();
    final queuePaths = _queue.map((track) => track.path).toList();
    final libraryTracks = _library
        .map((track) => jsonEncode(track.toJson()))
        .toList();
    final bookmarks = _bookmarks.map((track) => track.toJson()).toList();
    final playHistory = List<String>.of(_playHistory);
    final resumePositions = Map<String, int>.of(_resumePositions);
    final libraryFolders = List<String>.of(_libraryFolders);
    final podcastFeeds = List<String>.of(_podcastFeeds);
    final playlists = Map<String, List<String>>.fromEntries(
      _playlists.entries.map(
        (entry) => MapEntry(entry.key, List<String>.of(entry.value)),
      ),
    );
    final smartPlaylists = _smartPlaylists
        .map((playlist) => playlist.toJson())
        .toList();
    final plugins = _plugins.values.map((plugin) => plugin.toJson()).toList();
    final settings = <String, dynamic>{
      'volume': _volume,
      'balance': _balance,
      'crossfade': _crossfade,
      'crossfadeSeconds': _crossfadeSeconds,
      'equalizerEnabled': _equalizerEnabled,
      'eqPreset': _eqPreset,
      'eqBands': List<double>.of(_eqBands),
      'playbackSpeed': _playbackSpeed,
      'replayGainEnabled': _replayGainEnabled,
      'sleepTimerEndMs': _sleepDeadline?.millisecondsSinceEpoch,
      'librarySort': _librarySort,
      'librarySortDescending': _librarySortDescending,
      'libraryRelativePaths': Map<String, String>.of(_libraryRelativePaths),
      if (_playerLayoutCustomized)
        'playerControls': List<String>.of(_playerControls),
    };
    await prefs.setString('queueTracks', jsonEncode(queueTracks));
    await Future.wait([
      prefs.setStringList('queue', queuePaths),
      prefs.setStringList('library', libraryTracks),
      prefs.setString('bookmarks', jsonEncode(bookmarks)),
      prefs.setStringList('playHistory', playHistory),
      prefs.setString('resumePositions', jsonEncode(resumePositions)),
      prefs.setStringList('libraryFolders', libraryFolders),
      prefs.setStringList('podcastFeeds', podcastFeeds),
      prefs.setString('playlists', jsonEncode(playlists)),
      prefs.setString('smartPlaylists', jsonEncode(smartPlaylists)),
      prefs.setString('plugins', jsonEncode(plugins)),
      prefs.setString('settings', jsonEncode(settings)),
    ]);
  }

  Future<void> _addFiles() async {
    final operation = ++_libraryOperationGeneration;
    final queueWasEmpty = _queue.isEmpty;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'mp3',
        'flac',
        'wav',
        'ogg',
        'm4a',
        'm4b',
        'mp4',
        'aac',
        'wma',
        'opus',
        'ape',
        'aif',
        'aiff',
        'aifc',
        'mov',
        'webm',
        'mkv',
        'mka',
        ...midiFileExtensions,
        ...trackerModuleExtensions,
      ],
    );
    if (result.isEmpty || operation != _libraryOperationGeneration) return;
    var added = 0;
    var skipped = 0;
    for (final file in result) {
      final path = file.path;
      if (path == null || _queue.any((track) => track.path == path)) {
        skipped++;
        continue;
      }
      late final Track track;
      try {
        track = await _readTrack(path, file.name);
      } on Object {
        skipped++;
        continue;
      }
      if (!mounted || operation != _libraryOperationGeneration) return;
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == path)) _library.add(track);
      });
      added++;
    }
    if (!mounted || operation != _libraryOperationGeneration) return;
    await _saveQueue();
    if (!mounted || operation != _libraryOperationGeneration) return;
    if (queueWasEmpty && _queue.isNotEmpty) await _select(0);
    if (mounted && skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $added file(s); skipped $skipped.')),
      );
    }
  }

  Future<void> _addFolder() async {
    final operation = ++_libraryOperationGeneration;
    try {
      final directory = await _pickFolderLocation('Choose a music folder');
      if (directory == null || operation != _libraryOperationGeneration) return;
      final scanned = await _scanFolder(directory, operation: operation);
      if (operation != _libraryOperationGeneration) return;
      if (scanned == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No supported audio files found in that folder.'),
            ),
          );
        }
        return;
      }
      if (!mounted || operation != _libraryOperationGeneration) return;
      if (!_libraryFolders.contains(directory)) _libraryFolders.add(directory);
      await _saveQueue();
      if (!mounted || operation != _libraryOperationGeneration) return;
    } on Object catch (error) {
      if (!mounted || operation != _libraryOperationGeneration) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add music folder: $error')),
      );
    }
  }

  Future<String?> _pickFolderLocation(String dialogTitle) async {
    if (Platform.isAndroid) {
      final selection = await const MethodChannel('neonamp/library')
          .invokeMapMethod<String, dynamic>('pickFolder');
      final uri = selection?['uri'] as String?;
      if (uri == null || Uri.tryParse(uri)?.scheme.toLowerCase() != 'content') {
        return null;
      }
      return uri;
    }
    return FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
  }

  Future<void> _copyFileToFolder(
    String folder,
    String sourcePath,
    String fileName,
  ) async {
    if (Platform.isAndroid) {
      final copied = await const MethodChannel('neonamp/library')
          .invokeMethod<bool>('copyFileToFolder', {
            'uri': folder,
            'sourcePath': sourcePath,
            'fileName': fileName,
          });
      if (copied != true) throw StateError('Android could not copy the file.');
      return;
    }
    await File(sourcePath).copy('$folder${Platform.pathSeparator}$fileName');
  }

  Future<void> _writeTextToFolder(
    String folder,
    String fileName,
    String contents,
  ) async {
    if (Platform.isAndroid) {
      final written = await const MethodChannel('neonamp/library')
          .invokeMethod<bool>('writeTextToFolder', {
            'uri': folder,
            'fileName': fileName,
            'contents': contents,
          });
      if (written != true)
        throw StateError('Android could not write the playlist.');
      return;
    }
    await File('$folder${Platform.pathSeparator}$fileName')
        .writeAsString(contents);
  }

  Future<int> _scanFolder(String directory, {int? operation}) async {
    final List<({String path, String name, String relativePath})> files;
    if (Platform.isAndroid) {
      if (Uri.tryParse(directory)?.scheme.toLowerCase() != 'content') {
        throw StateError('Reselect this folder to grant Android media access.');
      }
      final results = await const MethodChannel('neonamp/library')
          .invokeListMethod<Map<Object?, Object?>>('scanFolder', {
            'uri': directory,
          });
      files = (results ?? [])
          .map((item) {
            final path = item['path'] as String?;
            if (path == null || path.isEmpty) return null;
            final name = item['name'] as String? ?? path;
            return (
              path: path,
              name: name,
              relativePath: item['relativePath'] as String? ?? name,
            );
          })
          .whereType<({String path, String name, String relativePath})>()
          .toList();
    } else {
      files = Directory(directory)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => isSupportedLibraryAudioPath(file.path))
          .map(
            (file) => (
              path: file.path,
              name: file.uri.pathSegments.last,
              relativePath: file.path
                  .substring(directory.length)
                  .replaceFirst(RegExp(r'^[/\\]+'), '')
                  .replaceAll('\\', '/'),
            ),
          )
          .toList();
    }
    var added = 0;
    for (final file in files) {
      final existingLibrary = _library
          .where((track) => track.path == file.path)
          .firstOrNull;
      final existingQueue = _queue
          .where((track) => track.path == file.path)
          .firstOrNull;
      late final Track scannedTrack;
      try {
        scannedTrack = await _readTrack(file.path, file.name);
      } on Object {
        continue;
      }
      final track = scannedTrack.copyWith(
        rating: existingLibrary?.rating ?? existingQueue?.rating,
        playCount: existingLibrary?.playCount ?? existingQueue?.playCount,
        favorite: existingLibrary?.favorite ?? existingQueue?.favorite,
      );
      if (!mounted ||
          (operation != null && operation != _libraryOperationGeneration)) {
        return 0;
      }
      setState(() {
        _libraryRelativePaths[file.path] = file.relativePath;
        final libraryIndex = _library.indexWhere(
          (item) => item.path == file.path,
        );
        if (libraryIndex >= 0) {
          _library[libraryIndex] = track;
        } else {
          _library.add(track);
        }
        final queueIndex = _queue.indexWhere((item) => item.path == file.path);
        if (queueIndex >= 0) {
          _queue[queueIndex] = track;
        } else {
          _queue.add(track);
        }
      });
      added++;
    }
    return added;
  }

  Future<void> _rescanFolders() async {
    final operation = ++_libraryOperationGeneration;
    if (_libraryFolders.isEmpty) {
      await _addFolder();
      return;
    }
    if (Platform.isAndroid) {
      final oldFilesystemFolders = _libraryFolders
          .where(
            (folder) => Uri.tryParse(folder)?.scheme.toLowerCase() != 'content',
          )
          .toList();
      if (oldFilesystemFolders.isNotEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Android needs you to reselect each saved music folder to restore access.',
            ),
          ),
        );
        for (final oldFolder in oldFilesystemFolders) {
          try {
            final directory = await _pickFolderLocation(
              'Choose a saved music folder again',
            );
            if (directory == null) return;
            await _scanFolder(directory, operation: operation);
            if (!mounted || operation != _libraryOperationGeneration) return;
            final index = _libraryFolders.indexOf(oldFolder);
            if (index >= 0) _libraryFolders[index] = directory;
            await _saveQueue();
            if (!mounted || operation != _libraryOperationGeneration) return;
          } on Object catch (error) {
            if (mounted && operation == _libraryOperationGeneration) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Could not restore folder access: $error'),
                ),
              );
            }
            return;
          }
        }
      }
    }
    for (final folder in List<String>.from(_libraryFolders)) {
      try {
        if (Platform.isAndroid || Directory(folder).existsSync()) {
          await _scanFolder(folder, operation: operation);
          if (!mounted || operation != _libraryOperationGeneration) return;
        }
      } on Object catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not rescan a library folder: $error')),
        );
      }
    }
    if (!mounted || operation != _libraryOperationGeneration) return;
    await _saveQueue();
    if (!mounted || operation != _libraryOperationGeneration) return;
    if (mounted && operation == _libraryOperationGeneration) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Rescanned ${_libraryFolders.length} folder(s)'),
        ),
      );
    }
  }

  Future<void> _importPlaylist() async {
    final operation = ++_libraryOperationGeneration;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'pls', 'b4s', 'wpl', 'asx'],
    );
    if (result.isEmpty ||
        result.first.path == null ||
        operation != _libraryOperationGeneration) {
      return;
    }
    final playlistPath = result.first.path!;
    try {
      final extension = playlistPath.split('.').last.toLowerCase();
      final document = parsePlaylistDocument(
        await File(playlistPath).readAsString(),
        extension,
      );
      var added = 0;
      var skipped = 0;
      if (!mounted || operation != _libraryOperationGeneration) return;
      setState(() {
        for (final entry in document.entries) {
          var path = resolvePlaylistPath(entry.path, playlistPath);
          if (path.isEmpty || path.startsWith('#')) continue;
          final uri = Uri.tryParse(path);
          final isStream = isHttpUri(uri);
          if (!isStream) {
            path =
                resolvePlaylistLibraryPath(
                  entryPath: entry.path,
                  resolvedPath: path,
                  libraryRelativePaths: _libraryRelativePaths,
                ) ??
                path;
            if (!path.startsWith('content:') && !File(path).existsSync()) {
              skipped++;
              continue;
            }
          }
          if (_queue.any((track) => track.path == path)) continue;
          final existingTrack = _library
              .where((track) => track.path == path)
              .firstOrNull;
          final fallbackName = isStream
              ? (uri?.host ?? 'Internet stream')
              : path.split(RegExp(r'[/\\]')).last;
          final track =
              existingTrack?.copyWith(
                name: entry.title?.isNotEmpty == true
                    ? entry.title!
                    : existingTrack.name,
              ) ??
              Track(
                path: path,
                name: entry.title?.isNotEmpty == true
                    ? entry.title!
                    : fallbackName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
                artist: isStream ? 'Online radio' : 'Local library',
              );
          _queue.add(track);
          if (!_library.any((item) => item.path == path)) _library.add(track);
          added++;
        }
      });
      await _saveQueue();
      if (mounted && operation == _libraryOperationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported $added track(s) from playlist.'
              '${skipped == 0 ? '' : ' $skipped local track(s) were not found in the library.'}',
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted && operation == _libraryOperationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import playlist: $error')),
        );
      }
    }
  }

  Future<void> _importItunesLibrary() async {
    final operation = ++_libraryOperationGeneration;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xml'],
      dialogTitle: 'Import an iTunes XML library',
    );
    final path = picked.firstOrNull?.path;
    if (path == null || operation != _libraryOperationGeneration) return;
    try {
      final imported = parseItunesLibrary(await File(path).readAsString());
      var addedTracks = 0;
      var addedPlaylists = 0;
      if (!mounted || operation != _libraryOperationGeneration) return;
      setState(() {
        for (final json in imported.tracks) {
          try {
            final track = Track.fromJson(Map<String, dynamic>.from(json));
            if (_library.any((item) => item.path == track.path)) continue;
            _library.add(track);
            addedTracks++;
          } on Object catch (trackError) {
            debugPrint('Skipping invalid iTunes track: $trackError');
          }
        }
        for (final playlist in imported.playlists.entries) {
          var name = playlist.key;
          var suffix = 2;
          while (_playlists.containsKey(name)) {
            name = '${playlist.key} (iTunes $suffix)';
            suffix++;
          }
          _playlists[name] = playlist.value;
          addedPlaylists++;
        }
      });
      await _saveQueue();
      if (mounted && operation == _libraryOperationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported $addedTracks tracks and $addedPlaylists playlists.',
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (mounted && operation == _libraryOperationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import iTunes library: $error')),
        );
      }
    }
  }

  Future<void> _exportItunesLibrary() async {
    final xml = buildItunesLibrary(
      _library.map((track) => track.toJson()),
      _playlists,
    );
    await FilePicker.saveFile(
      fileName: 'neonamp-library.xml',
      bytes: Uint8List.fromList(utf8.encode(xml)),
      mimeType: 'application/xml',
      type: FileType.custom,
      allowedExtensions: ['xml'],
    );
  }

  Future<void> _importCueSheet() async {
    final operation = ++_libraryOperationGeneration;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      dialogTitle: 'Select a CUE sheet and its audio file(s)',
      allowedExtensions: [
        'cue',
        'mp3',
        'flac',
        'm4a',
        'm4b',
        'mp4',
        'aac',
        'ape',
        'ogg',
        'opus',
        'wav',
        'wma',
        'aif',
        'aiff',
        'aifc',
        'webm',
        'mkv',
        'mka',
        'mov',
      ],
    );
    final cueInfo = picked
        .where((file) => file.extension?.toLowerCase() == 'cue')
        .firstOrNull;
    if (cueInfo?.path == null || operation != _libraryOperationGeneration) {
      return;
    }
    try {
      final cueFile = File(cueInfo!.path!);
      final text = utf8.decode(
        await cueFile.readAsBytes(),
        allowMalformed: true,
      );
      final entries = parseCueSheet(text, cueFile.path);
      final selectedAudio = picked
          .where(
            (file) =>
                file.path != null && file.extension?.toLowerCase() != 'cue',
          )
          .toList();
      final tracks = <Track>[];
      final sourceTracks = <String, Track>{};
      for (final entry in entries) {
        var audioPath = entry.filePath;
        if (!await File(audioPath).exists()) {
          final expectedName = entry.sourceFileName.toLowerCase();
          audioPath =
              selectedAudio
                  .where((file) => file.name.toLowerCase() == expectedName)
                  .firstOrNull
                  ?.path ??
              audioPath;
        }
        final audioFile = File(audioPath);
        if (!await audioFile.exists() ||
            !isSupportedLibraryAudioPath(audioFile.path)) {
          continue;
        }
        final metadata = await _readTrack(
          audioPath,
          audioFile.uri.pathSegments.last,
        );
        sourceTracks.putIfAbsent(audioPath, () => metadata);
        final fallbackName =
            '${metadata.name} · ${entry.trackNumber.toString().padLeft(2, '0')}';
        tracks.add(
          metadata.copyWith(
            name: entry.title?.trim().isNotEmpty == true
                ? entry.title!.trim()
                : fallbackName,
            artist: entry.performer?.trim().isNotEmpty == true
                ? entry.performer!.trim()
                : metadata.artist,
            album: entry.album?.trim().isNotEmpty == true
                ? entry.album!.trim()
                : metadata.album,
            trackNumber: entry.trackNumber,
            cueStartMs: entry.start.inMilliseconds,
            cueEndMs: entry.end?.inMilliseconds,
          ),
        );
      }
      var added = 0;
      if (!mounted || operation != _libraryOperationGeneration) return;
      setState(() {
        for (final track in tracks) {
          if (_queue.any((item) => item.identityKey == track.identityKey)) {
            continue;
          }
          _queue.add(track);
          added++;
        }
        for (final source in sourceTracks.values) {
          if (!_library.any((item) => item.path == source.path)) {
            _library.add(source);
          }
        }
      });
      await _saveQueue();
      if (mounted && operation == _libraryOperationGeneration) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Imported $added CUE track(s)')));
      }
    } on Object catch (error) {
      if (mounted && operation == _libraryOperationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import CUE sheet: $error')),
        );
      }
    }
  }

  Future<Track> _readTrack(String path, String fileName) async {
    final fallback = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    try {
      if (isMidiFilePath(path)) {
        return Track(path: path, name: fallback, artist: 'MIDI');
      }
      if (isTrackerModulePath(path)) {
        final module = await TrackerModuleDecoder.readInfo(path);
        return Track(
          path: path,
          name: module.title.trim().isEmpty ? fallback : module.title.trim(),
          artist:
              'Tracker module${module.format.trim().isEmpty ? '' : ' · ${module.format.trim()}'}',
          album: 'Tracker modules',
        );
      }
      final metadata = readTrackMetadata(File(path), getImage: true);
      final replayGainDb = readReplayGainDb(File(path));
      final hasContainerId3 = isAiffAudioPath(path) || isWavAudioPath(path);
      final containerId3 = hasContainerId3
          ? await File(path).readAsBytes()
          : null;
      final id3Numbers = containerId3 == null
          ? null
          : readContainerId3TrackDiscNumbers(containerId3);
      return Track(
        path: path,
        name: metadata.title?.trim().isNotEmpty == true
            ? metadata.title!.trim()
            : fallback,
        artist: metadata.artist?.trim().isNotEmpty == true
            ? metadata.artist!.trim()
            : 'Local library',
        album: metadata.album?.trim().isNotEmpty == true
            ? metadata.album!.trim()
            : 'Unknown album',
        genre: metadata.genres.isNotEmpty
            ? metadata.genres.first
            : 'Unknown genre',
        year: metadata.year?.year == 0 ? null : metadata.year?.year,
        trackNumber: id3Numbers?.track ?? metadata.trackNumber,
        trackTotal: id3Numbers?.trackTotal ?? metadata.trackTotal,
        discNumber: id3Numbers?.disc ?? metadata.discNumber,
        discTotal: id3Numbers?.discTotal ?? metadata.totalDisc,
        lyrics:
            metadata.lyrics ??
            (isAiffAudioPath(path)
                ? readAiffId3Lyrics(containerId3!)
                : isWavAudioPath(path)
                ? readWavId3Lyrics(containerId3!)
                : null),
        artwork: metadata.pictures.isNotEmpty
            ? metadata.pictures.first.bytes
            : (isAiffAudioPath(path) || isWavAudioPath(path))
            ? readAiffId3Picture(containerId3!)?.$1
            : null,
        replayGainDb: replayGainDb,
      );
    } catch (_) {
      return Track(path: path, name: fallback);
    }
  }

  Future<void> _playStandardTrack(Track track) async {
    await _player.setBalance(_balance);
    await _player.setVolume(_volumeFor(track));
    if (_audioHandler != null) {
      await _audioHandler!.playTrack(track, playbackSpeed: _playbackSpeed);
    } else {
      await _player.stop();
      await _player.play(
        isUriMediaPath(track.path)
            ? UrlSource(track.path)
            : DeviceFileSource(track.path),
      );
      await _player.setPlaybackRate(_playbackSpeed);
    }
  }

  Future<void> _select(int index) async {
    if (index < 0 ||
        index >= _queue.length ||
        _selectionInProgress ||
        _crossfadeInProgress) {
      return;
    }
    final operation = ++_queueOperationGeneration;
    _selectionInProgress = true;
    try {
      _castPositionTimer?.cancel();
      if (_casting) await _dlnaCast.stop();
    } on Object catch (error) {
      if (mounted && operation == _queueOperationGeneration) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop the previous track: $error')),
        );
      }
      _selectionInProgress = false;
      return;
    }
    if (!mounted || operation != _queueOperationGeneration) {
      _selectionInProgress = false;
      return;
    }
    try {
      setState(() {
        _selected = index;
        _position = Duration.zero;
        _cueTransitioning = false;
        final track = _queue[index];
        _playHistory
          ..clear()
          ..addAll(addToPlayHistory(_playHistory, track.identityKey));
        final libraryIndex = _library.indexWhere(
          (item) => item.identityKey == track.identityKey,
        );
        if (libraryIndex >= 0)
          _library[libraryIndex] = track.copyWith(
            playCount: track.playCount + 1,
          );
        _queue[index] = track.copyWith(playCount: track.playCount + 1);
      });
      final track = _queue[index];
      // Selecting a track explicitly is a user request to start that track.
      // Persisted positions are only playback bookkeeping and must not make a
      // later manual selection unexpectedly resume in the middle.
      _resumePositions.remove(track.identityKey);
      final trackVolume = _volumeFor(track);
      final shouldUseDsp =
          !isUriMediaPath(track.path) &&
          !isMidiFilePath(track.path) &&
          (_equalizerEnabled || isTrackerModulePath(track.path));
      if (Platform.isWindows && isMidiFilePath(track.path)) {
        if (_dspActive) {
          await _dspPlayer.stop();
          _dspActive = false;
        }
        if (!_midiActive) await _player.stop();
        _midiActive = true;
        await _midiPlayer.play(track.path, playbackSpeed: _playbackSpeed);
        _audioHandler?.publishTrack(track);
      } else if (shouldUseDsp) {
        if (_midiActive) {
          await _midiPlayer.stop();
          _midiActive = false;
        }
        if (!_dspActive) {
          await _player.stop();
          _dspActive = true;
        }
        try {
          await _dspPlayer.play(
            track.path,
            volume: trackVolume,
            playbackSpeed: _playbackSpeed,
            equalizerEnabled: _equalizerEnabled,
            bands: _eqBands,
            balance: _balance,
          );
          _audioHandler?.publishTrack(track);
        } on Object catch (error) {
          debugPrint('DSP playback unavailable; falling back to standard player: $error');
          await _dspPlayer.stop();
          _dspActive = false;
          await _playStandardTrack(track);
        }
      } else {
        if (_midiActive) {
          await _midiPlayer.stop();
          _midiActive = false;
        }
        if (_dspActive) {
          await _dspPlayer.stop();
          _dspActive = false;
        }
        await _playStandardTrack(track);
      }
      // Cue tracks still need their source cue offset applied. Ordinary tracks
      // already start at zero after playTrack()/AudioPlayer.play().
      if (track.cueStartMs != null) {
        await _seekCurrent(Duration.zero);
      }
      if (!mounted || operation != _queueOperationGeneration) return;
      await _saveQueue();
      if (!mounted || operation != _queueOperationGeneration) return;
    } on Object catch (error) {
      if (!mounted || operation != _queueOperationGeneration) return;
      _midiActive = false;
      _dspActive = false;
      setState(() {
        _playerState = PlayerState.stopped;
        _position = Duration.zero;
        _duration = Duration.zero;
      });
      _audioHandler?.syncExternalState(
        position: Duration.zero,
        state: PlayerState.stopped,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play this track: $error')),
      );
    } finally {
      _selectionInProgress = false;
    }
  }

  void _rememberResumePosition(Duration position) {
    final identity = _current?.identityKey;
    if (identity == null || position <= Duration.zero) return;
    final bounded = _duration > Duration.zero && position > _duration
        ? _duration
        : position;
    if (bounded <= Duration.zero) return;
    _resumePositions[identity] = bounded.inMilliseconds;
    _resumeSaveTimer?.cancel();
    _resumeSaveTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _saveQueueSafely();
    });
  }

  Future<void> _handleCompletionSafely() async {
    try {
      await _handleComplete();
    } on Object catch (error) {
      debugPrint('Playback completion handling failed: $error');
    }
  }

  Future<void> _togglePlay() async {
    // Importing media is an explicit library action. The transport control
    // must never open Android's file picker just because the queue is empty.
    // A restored queue can briefly exist before _current is initialized; in
    // that state the transport button should still start the selected track.
    if (_current == null) {
      if (_queue.isNotEmpty) await _select(_selected);
      return;
    }
    if (_isPlaying) {
      await _pauseCurrent();
    } else if (_playerState == PlayerState.paused) {
      await _playCurrent();
    } else {
      await _select(_selected);
    }
  }

  Future<void> _next({bool useCrossfade = true}) async {
    if (_queue.isEmpty || _crossfadeInProgress) return;
    final next = _targetNextIndex();
    final cueTransition =
        _current?.cueStartMs != null || _queue[next].cueStartMs != null;
    if (_midiActive || isMidiFilePath(_queue[next].path)) {
      useCrossfade = false;
    }
    if (useCrossfade &&
        !cueTransition &&
        _crossfade &&
        _isPlaying &&
        !_crossfadeInProgress) {
      await _crossfadeToNext(targetIndex: next);
      return;
    }
    await _select(next);
  }

  int _targetNextIndex() => nextQueueIndex(
    selected: _selected,
    length: _queue.length,
    shuffle: _shuffle,
    shuffledOffset: _shuffle && _queue.length > 1
        ? math.Random().nextInt(_queue.length - 1)
        : null,
  );

  Future<void> _crossfadeToNext({int? targetIndex}) async {
    if (_queue.isEmpty || _crossfadeInProgress) return;
    final next = targetIndex ?? _targetNextIndex();
    if (_current?.cueStartMs != null || _queue[next].cueStartMs != null) {
      return;
    }
    if (_dspActive) {
      await _crossfadeDspToNext(next);
      return;
    }
    _crossfadeInProgress = true;
    final previousPlayer = _player;
    final previousTrack = _queue[_selected];
    final track = _queue[next];
    final incomingPlayer = AudioPlayer();
    var promoted = false;
    _crossfadeAudioPlayer = incomingPlayer;
    try {
      await incomingPlayer.setBalance(_balance);
      if (!mounted) {
        await incomingPlayer.dispose();
        return;
      }
      setState(() {
        _selected = next;
        _position = Duration.zero;
        _playHistory
          ..clear()
          ..addAll(addToPlayHistory(_playHistory, track.identityKey));
        final updatedTrack = track.copyWith(playCount: track.playCount + 1);
        final libraryIndex = _library.indexWhere(
          (item) => item.path == track.path,
        );
        if (libraryIndex >= 0) {
          _library[libraryIndex] = updatedTrack;
        }
        _queue[next] = updatedTrack;
      });
      await incomingPlayer.setVolume(0);
      await incomingPlayer.setPlaybackRate(_playbackSpeed);
      await incomingPlayer.play(
        isUriMediaPath(track.path)
            ? UrlSource(track.path)
            : DeviceFileSource(track.path),
      );
      final steps = math.max(1, _crossfadeSeconds * 10);
      for (var step = 1; step <= steps; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted || !_crossfadeInProgress) {
          throw StateError('Crossfade was cancelled.');
        }
        final progress = step / steps;
        await previousPlayer.setVolume(
          _volumeFor(previousTrack) * (1 - progress),
        );
        await incomingPlayer.setVolume(_volumeFor(track) * progress);
      }
      await previousPlayer.stop();
      await previousPlayer.dispose();
      _activePlayer = incomingPlayer;
      promoted = true;
      _bindPlayerStreams();
      await _audioHandler?.switchPlayer(incomingPlayer);
      _audioHandler?.publishTrack(track);
      await _saveQueue();
    } catch (_) {
      if (!promoted) await incomingPlayer.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Crossfade could not start the next track.'),
          ),
        );
      }
    } finally {
      if (identical(_crossfadeAudioPlayer, incomingPlayer)) {
        _crossfadeAudioPlayer = null;
      }
      _crossfadeInProgress = false;
    }
  }

  Future<void> _crossfadeDspToNext(int next) async {
    if (_queue.isEmpty || _crossfadeInProgress) return;
    _crossfadeInProgress = true;
    final previousPlayer = _dspPlayer;
    final previousTrack = _queue[_selected];
    final track = _queue[next];
    final incomingPlayer = DspLocalPlayer();
    var promoted = false;
    _crossfadeDspPlayer = incomingPlayer;
    try {
      if (!mounted) return;
      setState(() {
        _selected = next;
        _position = Duration.zero;
        _playHistory
          ..clear()
          ..addAll(addToPlayHistory(_playHistory, track.identityKey));
        final updatedTrack = track.copyWith(playCount: track.playCount + 1);
        final libraryIndex = _library.indexWhere(
          (item) => item.path == track.path,
        );
        if (libraryIndex >= 0) {
          _library[libraryIndex] = updatedTrack;
        }
        _queue[next] = updatedTrack;
      });
      await incomingPlayer.play(
        track.path,
        volume: 0,
        playbackSpeed: _playbackSpeed,
        equalizerEnabled: _equalizerEnabled,
        bands: _eqBands,
        balance: _balance,
      );
      final steps = math.max(1, _crossfadeSeconds * 10);
      for (var step = 1; step <= steps; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted || !_crossfadeInProgress) {
          throw StateError('Crossfade was cancelled.');
        }
        final progress = step / steps;
        await previousPlayer.setVolume(
          _volumeFor(previousTrack) * (1 - progress),
        );
        await incomingPlayer.setVolume(_volumeFor(track) * progress);
      }
      await previousPlayer.stop();
      await previousPlayer.dispose();
      _dspPlayer = incomingPlayer;
      promoted = true;
      _bindDspStreams();
      _audioHandler?.publishTrack(track);
      await _saveQueue();
    } catch (_) {
      if (!promoted) await incomingPlayer.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Crossfade could not start the next track.'),
          ),
        );
      }
    } finally {
      if (identical(_crossfadeDspPlayer, incomingPlayer)) {
        _crossfadeDspPlayer = null;
      }
      _crossfadeInProgress = false;
    }
  }

  Future<void> _previous() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) return _seekCurrent(Duration.zero);
    await _select((_selected - 1 + _queue.length) % _queue.length);
  }

  Future<void> _remove(int index) async {
    if (!mounted ||
        _selectionInProgress ||
        _crossfadeInProgress ||
        index < 0 ||
        index >= _queue.length) {
      return;
    }
    final operation = ++_queueOperationGeneration;
    final removedIdentity = _queue[index].identityKey;
    final removingCurrent = index == _selected;
    if (removingCurrent) await _stopCurrent();
    if (!mounted || operation != _queueOperationGeneration) return;
    setState(() {
      _queue.removeAt(index);
      if (_queue.isEmpty) {
        _selected = 0;
      } else {
        if (index < _selected) _selected--;
        if (_selected >= _queue.length) _selected = _queue.length - 1;
      }
      if (removingCurrent) {
        _midiActive = false;
        _dspActive = false;
        _position = Duration.zero;
        _duration = Duration.zero;
        _playerState = PlayerState.stopped;
      }
    });
    _resumePositions.remove(removedIdentity);
    if (operation == _queueOperationGeneration) await _saveQueue();
  }

  bool _isBookmarked(Track track) =>
      _bookmarks.any((item) => item.identityKey == track.identityKey);

  Future<void> _toggleBookmark(Track track) async {
    if (!mounted) return;
    setState(() {
      final updated = toggleTrackBookmark(_bookmarks, track);
      _bookmarks
        ..clear()
        ..addAll(updated);
    });
    await _saveQueue();
  }

  Future<void> _playBookmark(Track track) async {
    if (!mounted || _crossfadeInProgress) return;
    final operation = ++_queueOperationGeneration;
    var index = _queue.indexWhere(
      (item) => item.identityKey == track.identityKey,
    );
    if (index < 0) {
      setState(() {
        _queue.add(track);
        index = _queue.length - 1;
      });
      if (operation != _queueOperationGeneration) return;
      await _saveQueue();
    }
    if (!mounted || operation != _queueOperationGeneration) return;
    await _select(index);
  }

  Future<void> _reorderQueue(int oldIndex, int newIndex) async {
    if (!mounted ||
        _selectionInProgress ||
        _crossfadeInProgress ||
        oldIndex == newIndex ||
        oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0) {
      return;
    }
    final operation = ++_queueOperationGeneration;
    final selectedIdentity = _current?.identityKey;
    setState(() {
      final track = _queue.removeAt(oldIndex);
      _queue.insert(newIndex.clamp(0, _queue.length), track);
      final selectedIndex = selectedIdentity == null
          ? -1
          : _queue.indexWhere((item) => item.identityKey == selectedIdentity);
      if (selectedIndex >= 0) _selected = selectedIndex;
    });
    if (operation == _queueOperationGeneration) await _saveQueue();
  }

  Future<void> _clearQueue() async {
    if (_selectionInProgress || _crossfadeInProgress) return;
    final operation = ++_queueOperationGeneration;
    _castPositionTimer?.cancel();
    _resumeSaveTimer?.cancel();
    await _stopCurrent();
    if (_dspActive) await _dspPlayer.stop();
    if (!mounted || operation != _queueOperationGeneration) return;
    setState(() {
      _midiActive = false;
      _dspActive = false;
      _queue.clear();
      _selected = 0;
      _position = Duration.zero;
      _duration = Duration.zero;
      _playerState = PlayerState.stopped;
      _resumePositions.clear();
    });
    if (operation == _queueOperationGeneration) await _saveQueue();
  }

  Future<void> _addStream() async {
    final operation = ++_queueOperationGeneration;
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add stream URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/stream.mp3',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (!mounted ||
        operation != _queueOperationGeneration ||
        url == null ||
        url.isEmpty) {
      return;
    }
    final uri = Uri.tryParse(url);
    if (!isHttpUri(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a valid HTTP or HTTPS stream URL.'),
          ),
        );
      }
      return;
    }
    if (_queue.any((track) => track.path == url)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That stream is already in the queue.')),
        );
      }
      return;
    }
    setState(
      () => _queue.add(
        Track(
          path: url,
          name: Uri.tryParse(url)?.host ?? 'Internet stream',
          artist: 'Online radio',
        ),
      ),
    );
    if (!mounted || operation != _queueOperationGeneration) return;
    await _saveQueue();
  }

  Future<void> _openVideoPicker() async {
    final selectedFiles = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedVideoExtensions.toList()..sort(),
      dialogTitle: 'Choose videos to play',
    );
    if (!mounted) return;
    final files = selectedFiles
        .where((file) => file.path != null && isSupportedVideoPath(file.path!))
        .map((file) => File(file.path!))
        .toList();
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No playable video files were selected.')),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => VideoPlayerPage(files: files)),
    );
  }

  Future<List<Map<String, dynamic>>> _searchShoutcastStations(
    String term,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.https('directory.shoutcast.com', '/Search/UpdateSearch'),
      );
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'NeonAmp/0.1');
      request.write(Uri(queryParameters: {'query': term}).query);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) return const [];
      final decoded = jsonDecode(body);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(normalizeShoutcastStation)
          .toList();
    } catch (_) {
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _resolveShoutcastStream(Map<String, dynamic> station) async {
    final id = (station['shoutcastId'] as num?)?.toInt();
    if (id == null) return null;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.https('directory.shoutcast.com', '/Player/GetStreamUrl'),
      );
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'NeonAmp/0.1');
      request.write(Uri(queryParameters: {'station': '$id'}).query);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) return null;
      final decoded = jsonDecode(body);
      return decoded is String && decoded.trim().isNotEmpty ? decoded : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _searchRadioDirectory() async {
    final controller = TextEditingController();
    final term = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Find internet radio'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Station, genre, or country',
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    if (term == null || term.trim().isEmpty) return;
    try {
      final uri = Uri.https(
        'de1.api.radio-browser.info',
        '/json/stations/search',
        {
          'name': term.trim(),
          'limit': '25',
          'order': 'votes',
          'reverse': 'true',
          'hidebroken': 'true',
        },
      );
      final client = HttpClient();
      late final HttpClientResponse response;
      String body;
      try {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.userAgentHeader, 'NeonAmp/0.1');
        response = await request.close();
        body = await utf8.decoder.bind(response).join();
      } finally {
        client.close(force: true);
      }
      if (response.statusCode != HttpStatus.ok)
        throw const HttpException('Radio directory request failed');
      final radioBrowserStations = (jsonDecode(body) as List)
          .whereType<Map<String, dynamic>>()
          .where((station) => _stationStreamUrl(station) != null)
          .map(normalizeRadioBrowserStation)
          .toList();
      final stations = mergeRadioStations([
        ...radioBrowserStations,
        ...await _searchShoutcastStations(term.trim()),
      ]);
      if (!mounted) return;
      if (stations.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No playable stations found.')),
        );
        return;
      }
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('Radio stations for “$term”'),
            content: SizedBox(
              width: 520,
              height: 420,
              child: ListView.builder(
                itemCount: stations.length,
                itemBuilder: (_, index) {
                  final station = stations[index];
                  final name = (station['name'] as String? ?? 'Untitled')
                      .trim();
                  final country = station['country'] as String? ?? '';
                  final codec = station['codec'] as String? ?? '';
                  final genre =
                      (station['genre'] as String? ??
                              station['tags'] as String? ??
                              '')
                          .split(',')
                          .first
                          .trim();
                  final listeners =
                      (station['listeners'] as num?)?.toInt() ?? 0;
                  final bitrate = (station['bitrate'] as num?)?.toInt() ?? 0;
                  final path = _stationStreamUrl(station);
                  final isShoutcast = station['source'] == 'SHOUTcast';
                  final saved = path == null
                      ? null
                      : _library.cast<Track?>().firstWhere(
                          (track) => track?.path == path,
                          orElse: () => null,
                        );
                  return ListTile(
                    leading: const Icon(Icons.radio, color: Color(0xffef4bff)),
                    title: Text(name.isEmpty ? 'Untitled station' : name),
                    subtitle: Text(
                      [
                        country,
                        codec,
                        if (genre.isNotEmpty) genre,
                        if (bitrate > 0) '$bitrate kbps',
                        if (listeners > 0) '$listeners listeners',
                      ].where((value) => value.isNotEmpty).join(' · '),
                    ),
                    trailing: IconButton(
                      tooltip: saved?.favorite == true
                          ? 'Remove station favorite'
                          : 'Save station favorite',
                      icon: Icon(
                        saved?.favorite == true
                            ? Icons.star
                            : Icons.star_border,
                        color: saved?.favorite == true ? Colors.amber : null,
                      ),
                      onPressed: path == null && !isShoutcast
                          ? null
                          : () async {
                              if (_stationStreamUrl(station) == null) {
                                final resolved = await _resolveShoutcastStream(
                                  station,
                                );
                                if (resolved != null) {
                                  station['streamUrl'] = resolved;
                                }
                              }
                              if (_stationStreamUrl(station) == null) return;
                              await _toggleRadioFavorite(station);
                              if (!context.mounted) return;
                              setDialogState(() {});
                            },
                    ),
                    onTap: () => Navigator.pop(context, station),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
      if (selected == null) return;
      var path = _stationStreamUrl(selected);
      if (path == null && selected['source'] == 'SHOUTcast') {
        path = await _resolveShoutcastStream(selected);
        if (path != null) selected['streamUrl'] = path;
      }
      if (path == null) return;
      if (!mounted) return;
      final name = (selected['name'] as String? ?? 'Internet radio').trim();
      final track = Track(
        path: path,
        name: name.isEmpty ? 'Internet radio' : name,
        artist: (selected['country'] as String? ?? 'Internet radio').trim(),
        album: 'Internet radio',
        genre:
            (selected['tags'] as String? ??
                    selected['genre'] as String? ??
                    'Radio')
                .split(',')
                .first
                .trim(),
      );
      final existingIndex = _queue.indexWhere((item) => item.path == path);
      if (existingIndex >= 0) {
        await _select(existingIndex);
        return;
      }
      setState(() {
        _queue.add(track);
        _library.removeWhere((item) => item.path == path);
        _library.add(track);
        _selected = _queue.length - 1;
      });
      await _select(_selected);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not reach the radio directory.')),
        );
      }
    }
  }

  String? _stationStreamUrl(Map<String, dynamic> station) {
    final shoutcast = station['streamUrl'] as String?;
    if (shoutcast != null && shoutcast.isNotEmpty) return shoutcast;
    final resolved = station['url_resolved'] as String?;
    final fallback = station['url'] as String?;
    final value = (resolved?.trim().isNotEmpty == true ? resolved : fallback)
        ?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _toggleRadioFavorite(Map<String, dynamic> station) async {
    final path = _stationStreamUrl(station);
    if (!mounted || path == null) return;
    final name = (station['name'] as String? ?? 'Internet radio').trim();
    final existingIndex = _library.indexWhere((track) => track.path == path);
    setState(() {
      if (existingIndex >= 0) {
        final track = _library[existingIndex];
        final updated = track.copyWith(favorite: !track.favorite);
        _library[existingIndex] = updated;
        for (var index = 0; index < _queue.length; index++) {
          if (_queue[index].path == path) _queue[index] = updated;
        }
      } else {
        _library.add(
          Track(
            path: path,
            name: name.isEmpty ? 'Internet radio' : name,
            artist: (station['country'] as String? ?? 'Internet radio').trim(),
            album: 'Internet radio',
            genre:
                (station['tags'] as String? ??
                        station['genre'] as String? ??
                        'Radio')
                    .split(',')
                    .first
                    .trim(),
            favorite: true,
          ),
        );
      }
    });
    await _saveQueue();
  }

  Future<void> _addPodcastFeed() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Subscribe to podcast RSS'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/podcast.xml',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Subscribe'),
          ),
        ],
      ),
    );
    if (!mounted || url == null || url.isEmpty) return;
    final parsed = Uri.tryParse(url);
    if (parsed == null || !isHttpUri(parsed) || parsed.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid podcast HTTP(S) URL.')),
        );
      }
      return;
    }
    if (_podcastFeeds.contains(url)) return;
    try {
      final added = await _loadPodcastFeed(url);
      if (!mounted) return;
      if (!_podcastFeeds.contains(url)) _podcastFeeds.add(url);
      await _saveQueue();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $added podcast episode(s)')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load that podcast feed.')),
        );
      }
    }
  }

  Future<void> _refreshPodcasts() async {
    var added = 0;
    for (final feed in List<String>.from(_podcastFeeds)) {
      try {
        added += await _loadPodcastFeed(feed);
      } catch (_) {
        // Keep other subscriptions refreshing if one feed is unavailable.
      }
      if (!mounted) return;
    }
    if (!mounted) return;
    await _saveQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Refreshed podcasts ($added new episode(s))')),
      );
    }
  }

  Future<void> _importPodcastSubscriptions() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['opml', 'xml'],
    );
    if (picked.isEmpty) return;
    final bytes = await picked.first.readAsBytes();
    final feeds = podcastFeedsFromOpml(
      utf8.decode(bytes, allowMalformed: true),
    );
    var addedFeeds = 0;
    var addedEpisodes = 0;
    for (final feed in feeds) {
      if (!mounted) return;
      if (_podcastFeeds.contains(feed)) continue;
      try {
        addedEpisodes += await _loadPodcastFeed(feed);
        if (!mounted) return;
        _podcastFeeds.add(feed);
        addedFeeds++;
      } on Exception {
        // A bad or temporarily unavailable feed must not block other imports.
      }
    }
    if (!mounted) return;
    await _saveQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported $addedFeeds podcast feed(s), $addedEpisodes new episode(s)',
          ),
        ),
      );
    }
  }

  Future<void> _exportPodcastSubscriptions() async {
    final bytes = Uint8List.fromList(
      utf8.encode(podcastFeedsToOpml(_podcastFeeds)),
    );
    await FilePicker.saveFile(
      fileName: 'neonamp-podcasts.opml',
      bytes: bytes,
      mimeType: 'text/x-opml',
      type: FileType.custom,
      allowedExtensions: ['opml'],
    );
  }

  Future<void> _managePodcastSubscriptions() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Podcast subscriptions'),
          content: SizedBox(
            width: 520,
            height: 360,
            child: _podcastFeeds.isEmpty
                ? const Center(child: Text('No podcast subscriptions yet.'))
                : ListView.builder(
                    itemCount: _podcastFeeds.length,
                    itemBuilder: (context, index) {
                      final feed = _podcastFeeds[index];
                      final uri = Uri.tryParse(feed);
                      return ListTile(
                        leading: const Icon(Icons.podcasts),
                        title: Text(
                          uri?.host.isNotEmpty == true ? uri!.host : feed,
                        ),
                        subtitle: Text(
                          feed,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'Unsubscribe',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (!dialogContext.mounted) return;
                            setDialogState(() => _podcastFeeds.remove(feed));
                            await _saveQueue();
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<int> _loadPodcastFeed(String feedUrl) async {
    final client = HttpClient();
    final String xml;
    try {
      final request = await client.getUrl(Uri.parse(feedUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'NeonAmp/0.1');
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Podcast feed returned ${response.statusCode}');
      }
      xml = await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
    final itemPattern = RegExp(
      r'<item\b[^>]*>([\s\S]*?)</item>',
      caseSensitive: false,
    );
    final enclosurePattern = RegExp(
      r'''<enclosure\b[^>]*\burl=["']([^"']+)["']''',
      caseSensitive: false,
    );
    final episodes = <Track>[];
    for (final match in itemPattern.allMatches(xml)) {
      final item = match.group(1) ?? '';
      final enclosure = enclosurePattern.firstMatch(item)?.group(1);
      final enclosureUri = enclosure == null ? null : Uri.tryParse(enclosure);
      if (enclosureUri == null ||
          !isHttpUri(enclosureUri) ||
          enclosureUri.host.isEmpty) {
        continue;
      }
      final title = _rssValue(item, 'title') ?? 'Podcast episode';
      final author =
          _rssValue(item, 'author') ?? _rssValue(item, 'creator') ?? 'Podcast';
      if (_queue.any((track) => track.path == enclosure)) continue;
      episodes.add(
        Track(
          path: enclosureUri.toString(),
          name: title,
          artist: author,
          album: 'Podcast',
          genre: 'Podcast',
        ),
      );
    }
    if (episodes.isNotEmpty && mounted) {
      setState(() {
        _queue.addAll(episodes);
        _library.addAll(
          episodes.where(
            (episode) => !_library.any((track) => track.path == episode.path),
          ),
        );
      });
    }
    return episodes.length;
  }

  Future<void> _downloadPodcastEpisode(Track track) async {
    final episodeUri = Uri.tryParse(track.path);
    if (episodeUri == null || !isHttpUri(episodeUri)) {
      return;
    }
    final directory = await _pickFolderLocation(
      'Choose a podcast download folder',
    );
    if (!mounted || directory == null) return;
    final client = HttpClient();
    try {
      final request = await client.getUrl(episodeUri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Episode returned ${response.statusCode}');
      }
      final safeName = track.name
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final baseName = safeName.isEmpty ? 'podcast-episode' : safeName;
      final extension = episodeUri.path.split('.').last.toLowerCase();
      final filename =
          '$baseName.${RegExp(r'^[a-z0-9]{1,5}$').hasMatch(extension) ? extension : 'mp3'}';
      final usedNames = <String>{};
      final safeFilename = nextSyncFileName(filename, usedNames);
      final target = Platform.isAndroid
          ? File(
              '${(await getApplicationSupportDirectory()).path}'
              '${Platform.pathSeparator}podcasts${Platform.pathSeparator}$safeFilename',
            )
          : File('$directory${Platform.pathSeparator}$safeFilename');
      await target.parent.create(recursive: true);
      await response.pipe(target.openWrite());
      if (Platform.isAndroid) {
        await _copyFileToFolder(directory, target.path, safeFilename);
      }
      final downloaded = track.copyWith(path: target.path, name: safeFilename);
      if (mounted) {
        setState(() {
          if (!_queue.any((item) => item.path == downloaded.path)) {
            _queue.add(downloaded);
          }
          if (!_library.any((item) => item.path == downloaded.path)) {
            _library.add(downloaded);
          }
        });
      }
      if (!mounted) return;
      await _saveQueue();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Downloaded ${track.name}')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not download this episode.')),
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  String? _rssValue(String item, String tag) {
    final match = RegExp(
      '<(?:[A-Za-z0-9_]+:)?$tag\\b[^>]*>([\\s\\S]*?)</(?:[A-Za-z0-9_]+:)?$tag>',
      caseSensitive: false,
    ).firstMatch(item);
    final value = match?.group(1)?.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (value == null || value.isEmpty) return null;
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  Future<void> _exportPlaylist() async {
    final bytes = Uint8List.fromList(
      utf8.encode('#EXTM3U\n${_queue.map((track) => track.path).join('\n')}\n'),
    );
    await FilePicker.saveFile(
      fileName: 'neonamp-playlist.m3u',
      bytes: bytes,
      mimeType: 'audio/x-mpegurl',
      type: FileType.custom,
      allowedExtensions: ['m3u'],
    );
  }

  Future<void> _exportB4sPlaylist() async {
    final xml = buildB4sPlaylist([
      for (final track in _queue)
        PlaylistEntry(path: track.path, title: track.name),
    ]);
    await FilePicker.saveFile(
      bytes: Uint8List.fromList(utf8.encode(xml)),
      fileName: 'neonamp-playlist.b4s',
      type: FileType.custom,
      allowedExtensions: ['b4s'],
    );
  }

  Future<void> _exportWplPlaylist() async {
    final xml = buildWplPlaylist([
      for (final track in _queue)
        PlaylistEntry(path: track.path, title: track.name),
    ]);
    await FilePicker.saveFile(
      bytes: Uint8List.fromList(utf8.encode(xml)),
      fileName: 'neonamp-playlist.wpl',
      type: FileType.custom,
      allowedExtensions: ['wpl'],
    );
  }

  Future<void> _exportAsxPlaylist() async {
    final xml = buildAsxPlaylist([
      for (final track in _queue)
        PlaylistEntry(path: track.path, title: track.name),
    ]);
    await FilePicker.saveFile(
      bytes: Uint8List.fromList(utf8.encode(xml)),
      fileName: 'neonamp-playlist.asx',
      type: FileType.custom,
      allowedExtensions: ['asx'],
    );
  }

  Future<void> _syncToDeviceFolder() async {
    final destination = await _pickFolderLocation(
      'Choose a device music folder',
    );
    if (destination == null) return;
    final selected = _selectedLibraryPaths.isEmpty
        ? _library
        : _library.where((track) => _selectedLibraryPaths.contains(track.path));
    final tracks = <Track>[];
    final seen = <String>{};
    for (final track in selected) {
      if (isUriMediaPath(track.path)) continue;
      if (seen.add(track.path)) tracks.add(track);
    }
    if (tracks.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No local tracks are available to sync.')),
      );
      return;
    }

    final usedNames = <String>{};
    final manifest = <String>['#EXTM3U'];
    var copied = 0;
    var skipped = 0;
    for (final track in tracks) {
      final source = File(track.path);
      if (!await source.exists()) {
        skipped++;
        continue;
      }
      final name = nextSyncFileName(syncFileName(track.path), usedNames);
      final samePath =
          !Platform.isAndroid &&
          source.absolute.path.toLowerCase() ==
              File('$destination${Platform.pathSeparator}$name').absolute.path
                  .toLowerCase();
      if (samePath) {
        manifest.add(name);
        copied++;
        continue;
      }
      try {
        await _copyFileToFolder(destination, track.path, name);
        manifest
          ..add('#EXTINF:-1,${track.name}')
          ..add(name);
        copied++;
      } on Object {
        skipped++;
      }
    }
    try {
      await _writeTextToFolder(
        destination,
        'neonamp-sync.m3u8',
        '${manifest.join('\n')}\n',
      );
    } on Object {
      skipped++;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Synced $copied track${copied == 1 ? '' : 's'}'
          '${skipped == 0 ? '' : ' · $skipped skipped'}',
        ),
      ),
    );
  }

  Future<void> _convertTrackToM4a(Track track) async {
    if (isUriMediaPath(track.path)) return;
    final destination = await _pickFolderLocation('Choose a conversion folder');
    if (!mounted || destination == null) return;
    final usedNames = <String>{};
    final requested = convertedM4aFileName(track.path);
    final outputName = nextSyncFileName(requested, usedNames);
    var output = '$destination${Platform.pathSeparator}$outputName';
    try {
      if (Platform.isAndroid) {
        final supportDirectory = await getApplicationSupportDirectory();
        final convertedDirectory = Directory(
          '${supportDirectory.path}${Platform.pathSeparator}converted',
        );
        await convertedDirectory.create(recursive: true);
        output =
            '${convertedDirectory.path}${Platform.pathSeparator}$outputName';
      }
      final converted = await const MethodChannel('neonamp/converter')
          .invokeMethod<bool>('convertToM4a', {
            'inputPath': track.path,
            'outputPath': output,
          });
      if (converted != true) {
        throw const FormatException(
          'The native audio converter rejected the file.',
        );
      }
      try {
        await writeTrackMetadata(File(output), [
          track.name,
          track.artist,
          track.album,
          track.genre,
          '',
          track.year?.toString() ?? '',
          track.trackNumber?.toString() ?? '',
          track.trackTotal?.toString() ?? '',
          track.discNumber?.toString() ?? '',
          track.discTotal?.toString() ?? '',
          track.lyrics ?? '',
        ]);
      } on Object {
        // The converted audio remains usable if a target tag writer rejects a field.
      }
      if (Platform.isAndroid) {
        await _copyFileToFolder(destination, output, outputName);
      }
      final convertedTrack = await _readTrack(output, outputName);
      final withMetadata = convertedTrack.copyWith(
        name: track.name,
        artist: track.artist,
        album: track.album,
        genre: track.genre,
        year: track.year,
        trackNumber: track.trackNumber,
        trackTotal: track.trackTotal,
        discNumber: track.discNumber,
        discTotal: track.discTotal,
        lyrics: track.lyrics,
      );
      if (!mounted) return;
      setState(() {
        if (!_library.any((item) => item.path == output)) {
          _library.add(withMetadata);
        }
      });
      if (!mounted) return;
      await _saveQueue();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Converted ${track.name} to M4A')),
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not convert track: $error')),
      );
    }
  }

  Future<void> _importAudioCd() async {
    try {
      final raw = await const MethodChannel('neonamp/system_controls')
          .invokeMethod<List<dynamic>>('listAudioCds');
      final discs = (raw ?? [])
          .whereType<Map>()
          .map((disc) => Map<String, dynamic>.from(disc))
          .toList();
      if (discs.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No audio CD drives are available.')),
        );
        return;
      }
      final choices = <Map<String, dynamic>>[];
      for (final disc in discs) {
        final drive = disc['drive'] as String? ?? '';
        for (final track in (disc['tracks'] as List? ?? []).whereType<Map>()) {
          choices.add({
            'drive': drive,
            'track': (track['track'] as num?)?.toInt() ?? 0,
            'durationSeconds': (track['durationSeconds'] as num?)?.toInt() ?? 0,
          });
        }
      }
      if (!mounted) return;
      final selection = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Import audio CD track'),
          children: choices
              .map(
                (choice) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, choice),
                  child: Text(
                    '${choice['drive']} · Track ${choice['track']} · '
                    '${_time(Duration(seconds: choice['durationSeconds'] as int))}',
                  ),
                ),
              )
              .toList(),
        ),
      );
      if (!mounted || selection == null) return;
      final destination = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a CD rip folder',
      );
      if (!mounted || destination == null) return;
      final drive = selection['drive'] as String;
      final trackNumber = selection['track'] as int;
      final outputName = nextSyncFileName(
        'CD ${drive.replaceAll(':', '')} Track $trackNumber.wav',
        <String>{},
      );
      final output = '$destination${Platform.pathSeparator}$outputName';
      final ripped = await const MethodChannel('neonamp/system_controls')
          .invokeMethod<bool>('ripAudioCd', {
            'drive': drive,
            'track': trackNumber,
            'outputPath': output,
          });
      if (ripped != true) throw const FormatException('CD rip failed.');
      final track = await _readTrack(output, outputName);
      if (!mounted) return;
      setState(() {
        _queue.add(track);
        _library.add(track);
        _selected = _queue.length - 1;
      });
      await _saveQueue();
      if (mounted) await _select(_selected);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not import CD: $error')));
    }
  }

  Future<void> _exportPlsPlaylist() async {
    final lines = <String>['[playlist]'];
    for (var index = 0; index < _queue.length; index++) {
      final track = _queue[index];
      final number = index + 1;
      lines
        ..add('File$number=${track.path}')
        ..add('Title$number=${track.name}')
        ..add('Length$number=-1');
    }
    lines
      ..add('NumberOfEntries=${_queue.length}')
      ..add('Version=2');
    await FilePicker.saveFile(
      bytes: Uint8List.fromList(utf8.encode('${lines.join('\n')}\n')),
      fileName: 'neonamp-playlist.pls',
      type: FileType.custom,
      allowedExtensions: ['pls'],
    );
  }

  List<Track> get _visibleLibrary {
    final query = _searchQuery.toLowerCase();
    final tracks = _library
        .where(
          (track) =>
              (_libraryFilter == 'All' ||
                  (_libraryFilter == 'Favorites' && track.favorite) ||
                  (_libraryFilter == 'Top rated' && track.rating >= 4) ||
                  (_libraryFilter == 'Most played' && track.playCount > 0)) &&
              (query.isEmpty ||
                  '${track.name} ${track.artist} ${track.album} ${track.genre}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
    if (_librarySort == 'Added') return tracks;
    tracks.sort((a, b) {
      final comparison = switch (_librarySort) {
        'Title' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        'Artist' => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
        'Album' => a.album.toLowerCase().compareTo(b.album.toLowerCase()),
        'Rating' => a.rating.compareTo(b.rating),
        'Play count' => a.playCount.compareTo(b.playCount),
        _ => 0,
      };
      return _librarySortDescending ? -comparison : comparison;
    });
    return tracks;
  }

  List<Track> _tracksForSmartPlaylist(SmartPlaylist playlist) {
    final tracks = _library.where((track) {
      bool matches(SmartCriterion criterion) {
        final value = criterion.value.toLowerCase();
        switch (criterion.rule) {
          case 'Favorites':
            return track.favorite;
          case 'Top rated':
            return track.rating >= 4;
          case 'Most played':
            return track.playCount > 0;
          case 'Rating at least':
            return track.rating >= (int.tryParse(criterion.value) ?? 0);
          case 'Played at least':
            return track.playCount >= (int.tryParse(criterion.value) ?? 0);
          case 'Genre':
            return track.genre.toLowerCase() == value;
          case 'Artist':
            return track.artist.toLowerCase() == value;
          default:
            return false;
        }
      }

      final results = playlist.effectiveCriteria.map(matches);
      return playlist.matchAll
          ? results.every((result) => result)
          : results.any((result) => result);
    }).toList();
    if (playlist.sortBy != 'Added') {
      tracks.sort((a, b) {
        final comparison = switch (playlist.sortBy) {
          'Title' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'Artist' => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
          'Album' => a.album.toLowerCase().compareTo(b.album.toLowerCase()),
          'Rating' => a.rating.compareTo(b.rating),
          'Play count' => a.playCount.compareTo(b.playCount),
          _ => 0,
        };
        return playlist.descending ? -comparison : comparison;
      });
    }
    if (playlist.limit > 0 && tracks.length > playlist.limit) {
      return tracks.sublist(0, playlist.limit);
    }
    return tracks;
  }

  void _toggleFavorite(Track track) {
    final index = _library.indexWhere((item) => item.path == track.path);
    if (index < 0) return;
    final updated = track.copyWith(favorite: !track.favorite);
    setState(() {
      _library[index] = updated;
      for (var queueIndex = 0; queueIndex < _queue.length; queueIndex++) {
        if (_queue[queueIndex].path == track.path) {
          _queue[queueIndex] = _queue[queueIndex].copyWith(
            favorite: updated.favorite,
          );
        }
      }
    });
    _saveQueueSafely();
  }

  Future<void> _editTrack(Track track) async {
    final title = TextEditingController(text: track.name);
    final artist = TextEditingController(text: track.artist);
    final album = TextEditingController(text: track.album);
    final genre = TextEditingController(text: track.genre);
    final year = TextEditingController(text: track.year?.toString() ?? '');
    final trackNumber = TextEditingController(
      text: track.trackNumber?.toString() ?? '',
    );
    final trackTotal = TextEditingController(
      text: track.trackTotal?.toString() ?? '',
    );
    final discNumber = TextEditingController(
      text: track.discNumber?.toString() ?? '',
    );
    final discTotal = TextEditingController(
      text: track.discTotal?.toString() ?? '',
    );
    final lyrics = TextEditingController(text: track.lyrics ?? '');
    var rating = track.rating;
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit metadata'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: artist,
                  decoration: const InputDecoration(labelText: 'Artist'),
                ),
                TextField(
                  controller: album,
                  decoration: const InputDecoration(labelText: 'Album'),
                ),
                TextField(
                  controller: genre,
                  decoration: const InputDecoration(labelText: 'Genre'),
                ),
                TextField(
                  controller: year,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Release year'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: trackNumber,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Track #'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: trackTotal,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Tracks'),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: discNumber,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Disc #'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: discTotal,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Discs'),
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: lyrics,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Lyrics'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Rating'),
                    const SizedBox(width: 8),
                    for (var star = 1; star <= 5; star++)
                      IconButton(
                        tooltip: '$star star${star == 1 ? '' : 's'}',
                        onPressed: () => setDialogState(() => rating = star),
                        icon: Icon(
                          star <= rating ? Icons.star : Icons.star_border,
                          color: const Color(0xffffd166),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, [
                title.text.trim(),
                artist.text.trim(),
                album.text.trim(),
                genre.text.trim(),
                '$rating',
                year.text.trim(),
                trackNumber.text.trim(),
                trackTotal.text.trim(),
                discNumber.text.trim(),
                discTotal.text.trim(),
                lyrics.text,
              ]),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (values == null || values.length != 11) return;
    var metadataPersisted = true;
    try {
      await writeTrackMetadata(File(track.path), values);
      final written = readTrackMetadata(File(track.path));
      final titleMatches =
          values[0].isEmpty || written.title?.trim() == values[0];
      final artistMatches =
          values[1].isEmpty || written.artist?.trim() == values[1];
      final albumMatches =
          values[2].isEmpty || written.album?.trim() == values[2];
      final genreMatches =
          values[3].isEmpty ||
          written.genres.any((genre) => genre == values[3]);
      final year = int.tryParse(values[5]);
      final trackNumber = int.tryParse(values[6]);
      final trackTotal = int.tryParse(values[7]);
      final discNumber = int.tryParse(values[8]);
      final discTotal = int.tryParse(values[9]);
      final writtenLyrics = isAiffAudioPath(track.path)
          ? readAiffId3Lyrics(await File(track.path).readAsBytes())
          : isWavAudioPath(track.path)
          ? readWavId3Lyrics(await File(track.path).readAsBytes())
          : written.lyrics;
      final customId3Numbers =
          isAiffAudioPath(track.path) || isWavAudioPath(track.path)
          ? readContainerId3TrackDiscNumbers(
              await File(track.path).readAsBytes(),
            )
          : null;
      final writtenTrackNumber = customId3Numbers?.track ?? written.trackNumber;
      final writtenTrackTotal =
          customId3Numbers?.trackTotal ?? written.trackTotal;
      final writtenDiscNumber = customId3Numbers?.disc ?? written.discNumber;
      final writtenDiscTotal = customId3Numbers?.discTotal ?? written.totalDisc;
      final metadataMatches =
          (year == null || written.year?.year == year) &&
          (trackNumber == null || writtenTrackNumber == trackNumber) &&
          (trackTotal == null || writtenTrackTotal == trackTotal) &&
          (discNumber == null || writtenDiscNumber == discNumber) &&
          (discTotal == null || writtenDiscTotal == discTotal) &&
          (values[10].trim().isEmpty || writtenLyrics == values[10]);
      if (!titleMatches ||
          !artistMatches ||
          !albumMatches ||
          !genreMatches ||
          !metadataMatches) {
        throw const FormatException(
          'Metadata writer did not persist the changes.',
        );
      }
    } catch (_) {
      metadataPersisted = false;
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This file format does not support tag writing yet.'),
          ),
        );
    }
    if (!metadataPersisted) return;
    final updated = track.copyWith(
      name: values[0],
      artist: values[1],
      album: values[2],
      genre: values[3],
      rating: (int.tryParse(values[4]) ?? track.rating).clamp(0, 5).toInt(),
      year: int.tryParse(values[5]) ?? track.year,
      trackNumber: int.tryParse(values[6]) ?? track.trackNumber,
      trackTotal: int.tryParse(values[7]) ?? track.trackTotal,
      discNumber: int.tryParse(values[8]) ?? track.discNumber,
      discTotal: int.tryParse(values[9]) ?? track.discTotal,
      lyrics: values[10].trim().isEmpty ? null : values[10],
      clearLyrics: values[10].trim().isEmpty,
    );
    if (!mounted) return;
    setState(() {
      final libraryIndex = _library.indexWhere(
        (item) => item.path == track.path,
      );
      if (libraryIndex >= 0) _library[libraryIndex] = updated;
      for (var i = 0; i < _queue.length; i++) {
        if (_queue[i].path == track.path) _queue[i] = updated;
      }
    });
    await _saveQueue();
  }

  void _toggleLibrarySelection(Track track) {
    setState(() {
      if (!_selectedLibraryPaths.add(track.path)) {
        _selectedLibraryPaths.remove(track.path);
      }
    });
  }

  Future<void> _editSelectedTracks() async {
    final selected = _library
        .where((track) => _selectedLibraryPaths.contains(track.path))
        .toList();
    if (selected.isEmpty) return;
    final artist = TextEditingController();
    final album = TextEditingController();
    final genre = TextEditingController();
    final year = TextEditingController();
    final rating = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit ${selected.length} tracks'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Leave a field empty to keep each track’s current value.',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
              TextField(
                controller: artist,
                decoration: const InputDecoration(labelText: 'Artist'),
              ),
              TextField(
                controller: album,
                decoration: const InputDecoration(labelText: 'Album'),
              ),
              TextField(
                controller: genre,
                decoration: const InputDecoration(labelText: 'Genre'),
              ),
              TextField(
                controller: year,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Release year'),
              ),
              TextField(
                controller: rating,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Rating (0–5)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [
              artist.text.trim(),
              album.text.trim(),
              genre.text.trim(),
              year.text.trim(),
              rating.text.trim(),
            ]),
            child: const Text('Apply to selected'),
          ),
        ],
      ),
    );
    if (!mounted || values == null) return;

    var updatedCount = 0;
    var failedCount = 0;
    final updatedTracks = <String, Track>{};
    for (final track in selected) {
      final updated = track.copyWith(
        artist: values[0].isEmpty ? track.artist : values[0],
        album: values[1].isEmpty ? track.album : values[1],
        genre: values[2].isEmpty ? track.genre : values[2],
        year: values[3].isEmpty ? track.year : int.tryParse(values[3]),
        rating: values[4].isEmpty
            ? track.rating
            : (int.tryParse(values[4]) ?? track.rating).clamp(0, 5).toInt(),
      );
      final metadataValues = [
        updated.name,
        updated.artist,
        updated.album,
        updated.genre,
        '${updated.rating}',
        updated.year?.toString() ?? '',
        updated.trackNumber?.toString() ?? '',
        updated.trackTotal?.toString() ?? '',
        updated.discNumber?.toString() ?? '',
        updated.discTotal?.toString() ?? '',
        updated.lyrics ?? '',
      ];
      try {
        await writeTrackMetadata(File(track.path), metadataValues);
        updatedTracks[track.path] = updated;
        updatedCount++;
      } catch (_) {
        failedCount++;
      }
    }
    if (!mounted) return;
    setState(() {
      for (var index = 0; index < _library.length; index++) {
        final updated = updatedTracks[_library[index].path];
        if (updated != null) _library[index] = updated;
      }
      for (var index = 0; index < _queue.length; index++) {
        final updated = updatedTracks[_queue[index].path];
        if (updated != null) _queue[index] = updated;
      }
      _selectedLibraryPaths.clear();
    });
    await _saveQueue();
    if (!mounted) return;
    if (failedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$updatedCount updated; $failedCount failed.')),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$updatedCount tracks updated.')));
    }
  }

  Future<void> _replaceArtwork(Track track) async {
    if (isUriMediaPath(track.path)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cover art can only be embedded in local files.'),
        ),
      );
      return;
    }
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (!mounted || result.isEmpty || result.first.path == null) return;
    try {
      final imageFile = File(result.first.path!);
      final bytes = await imageFile.readAsBytes();
      if (bytes.isEmpty) throw const FormatException('The image is empty.');
      final extension = imageFile.path.split('.').last.toLowerCase();
      final mimeType = switch (extension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      if (isAiffAudioPath(track.path) || isWavAudioPath(track.path)) {
        final writer = isWavAudioPath(track.path)
            ? writeWavTags
            : writeAiffTags;
        await writer(
          File(track.path),
          [
            track.name,
            track.artist,
            track.album,
            track.genre,
            '',
            track.year?.toString() ?? '',
            track.trackNumber?.toString() ?? '',
            track.trackTotal?.toString() ?? '',
            track.discNumber?.toString() ?? '',
            track.discTotal?.toString() ?? '',
            track.lyrics ?? '',
          ],
          artwork: bytes,
          artworkMimeType: mimeType,
        );
      } else if (isAsfAudioPath(track.path)) {
        await writeAsfTags(
          File(track.path),
          [
            track.name,
            track.artist,
            track.album,
            track.genre,
            '',
            track.year?.toString() ?? '',
            track.trackNumber?.toString() ?? '',
            track.trackTotal?.toString() ?? '',
            track.discNumber?.toString() ?? '',
            track.discTotal?.toString() ?? '',
            track.lyrics ?? '',
          ],
          artwork: bytes,
          artworkMimeType: mimeType,
        );
      } else if (isVorbisAudioPath(track.path)) {
        await writeVorbisTags(
          File(track.path),
          [
            track.name,
            track.artist,
            track.album,
            track.genre,
            '',
            track.year?.toString() ?? '',
            track.trackNumber?.toString() ?? '',
            track.trackTotal?.toString() ?? '',
            track.discNumber?.toString() ?? '',
            track.discTotal?.toString() ?? '',
            track.lyrics ?? '',
          ],
          artwork: bytes,
          artworkMimeType: mimeType,
        );
      } else if (isAacAudioPath(track.path)) {
        await writeAacArtwork(
          File(track.path),
          [
            track.name,
            track.artist,
            track.album,
            track.genre,
            '',
            track.year?.toString() ?? '',
            track.trackNumber?.toString() ?? '',
            track.trackTotal?.toString() ?? '',
            track.discNumber?.toString() ?? '',
            track.discTotal?.toString() ?? '',
            track.lyrics ?? '',
          ],
          bytes,
          mimeType,
        );
      } else {
        updateMetadata(File(track.path), (metadata) {
          metadata.setPictures([
            Picture(bytes, mimeType, PictureType.coverFront),
          ]);
        });
      }
      if (!mounted) return;
      final updated = track.copyWith(artwork: bytes);
      setState(() {
        final libraryIndex = _library.indexWhere(
          (item) => item.path == track.path,
        );
        if (libraryIndex >= 0) _library[libraryIndex] = updated;
        for (var i = 0; i < _queue.length; i++) {
          if (_queue[i].path == track.path) _queue[i] = updated;
        }
      });
      await _saveQueue();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Embedded cover art updated.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This file format cannot embed cover art.'),
          ),
        );
      }
    }
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Late night synthwave'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (!mounted || name == null || name.isEmpty) return;
    setState(() => _playlists[name] = []);
    await _saveQueue();
  }

  Future<void> _renamePlaylist(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (!mounted || name == null || name.isEmpty || name == oldName) return;
    if (_playlists.containsKey(name)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A playlist with that name already exists.'),
          ),
        );
      }
      return;
    }
    setState(() {
      final renamed = <String, List<String>>{};
      for (final entry in _playlists.entries) {
        renamed[entry.key == oldName ? name : entry.key] = entry.value;
      }
      _playlists
        ..clear()
        ..addAll(renamed);
    });
    await _saveQueue();
  }

  Future<void> _deletePlaylist(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Remove "$name"? The audio files will stay in your library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _playlists.remove(name));
    await _saveQueue();
  }

  Future<void> _editPlaylist(String name) async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final tracks = _playlists[name] ?? <String>[];
          return AlertDialog(
            title: Text('Edit $name'),
            content: SizedBox(
              width: 420,
              height: 360,
              child: tracks.isEmpty
                  ? const Center(child: Text('No tracks in this playlist.'))
                  : ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final path = tracks[index];
                        final track = _library.firstWhere(
                          (item) => item.path == path,
                          orElse: () => Track(
                            path: path,
                            name: path.split(RegExp(r'[/\\]')).last,
                          ),
                        );
                        return ListTile(
                          dense: true,
                          title: Text(track.name),
                          subtitle: Text(track.artist),
                          trailing: IconButton(
                            tooltip: 'Remove from playlist',
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () {
                              if (!mounted || !context.mounted) return;
                              setState(() => tracks.removeAt(index));
                              setDialogState(() {});
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
    await _saveQueue();
  }

  Future<void> _createSmartPlaylist() async {
    final nameController = TextEditingController();
    final valueController = TextEditingController();
    final secondValueController = TextEditingController();
    var rule = 'Favorites';
    var secondRule = 'None';
    var matchAll = true;
    var sortBy = 'Added';
    var descending = false;
    var limit = 0;
    final limitController = TextEditingController();
    final result = await showDialog<SmartPlaylist>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('New smart playlist'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: rule,
                decoration: const InputDecoration(labelText: 'Rule'),
                items: const [
                  DropdownMenuItem(
                    value: 'Favorites',
                    child: Text('Favorites'),
                  ),
                  DropdownMenuItem(
                    value: 'Top rated',
                    child: Text('Top rated'),
                  ),
                  DropdownMenuItem(
                    value: 'Most played',
                    child: Text('Most played'),
                  ),
                  DropdownMenuItem(value: 'Genre', child: Text('Genre is')),
                  DropdownMenuItem(value: 'Artist', child: Text('Artist is')),
                  DropdownMenuItem(
                    value: 'Rating at least',
                    child: Text('Rating at least'),
                  ),
                  DropdownMenuItem(
                    value: 'Played at least',
                    child: Text('Played at least'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => rule = value);
                },
              ),
              if (rule == 'Genre' ||
                  rule == 'Artist' ||
                  rule == 'Rating at least' ||
                  rule == 'Played at least')
                TextField(
                  controller: valueController,
                  keyboardType:
                      rule == 'Rating at least' || rule == 'Played at least'
                      ? TextInputType.number
                      : null,
                  decoration: InputDecoration(
                    labelText: switch (rule) {
                      'Genre' => 'Genre',
                      'Artist' => 'Artist',
                      'Rating at least' => 'Minimum rating (1-5)',
                      _ => 'Minimum play count',
                    },
                  ),
                ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: secondRule,
                decoration: const InputDecoration(
                  labelText: 'Second rule (optional)',
                ),
                items: const [
                  DropdownMenuItem(value: 'None', child: Text('None')),
                  DropdownMenuItem(
                    value: 'Favorites',
                    child: Text('Favorites'),
                  ),
                  DropdownMenuItem(
                    value: 'Top rated',
                    child: Text('Top rated'),
                  ),
                  DropdownMenuItem(
                    value: 'Most played',
                    child: Text('Most played'),
                  ),
                  DropdownMenuItem(value: 'Genre', child: Text('Genre is')),
                  DropdownMenuItem(value: 'Artist', child: Text('Artist is')),
                  DropdownMenuItem(
                    value: 'Rating at least',
                    child: Text('Rating at least'),
                  ),
                  DropdownMenuItem(
                    value: 'Played at least',
                    child: Text('Played at least'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => secondRule = value);
                },
              ),
              if (secondRule != 'None' &&
                  (secondRule == 'Genre' ||
                      secondRule == 'Artist' ||
                      secondRule == 'Rating at least' ||
                      secondRule == 'Played at least'))
                TextField(
                  controller: secondValueController,
                  keyboardType:
                      secondRule == 'Rating at least' ||
                          secondRule == 'Played at least'
                      ? TextInputType.number
                      : null,
                  decoration: InputDecoration(
                    labelText: switch (secondRule) {
                      'Genre' => 'Second genre',
                      'Artist' => 'Second artist',
                      'Rating at least' => 'Second minimum rating',
                      _ => 'Second minimum play count',
                    },
                  ),
                ),
              if (secondRule != 'None')
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(matchAll ? 'Match all rules' : 'Match any rule'),
                  value: matchAll,
                  onChanged: (value) => setDialogState(() => matchAll = value),
                ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: sortBy,
                decoration: const InputDecoration(labelText: 'Sort by'),
                items: const [
                  DropdownMenuItem(value: 'Added', child: Text('Added order')),
                  DropdownMenuItem(value: 'Title', child: Text('Title')),
                  DropdownMenuItem(value: 'Artist', child: Text('Artist')),
                  DropdownMenuItem(value: 'Album', child: Text('Album')),
                  DropdownMenuItem(value: 'Rating', child: Text('Rating')),
                  DropdownMenuItem(
                    value: 'Play count',
                    child: Text('Play count'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setDialogState(() => sortBy = value);
                },
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Descending'),
                value: descending,
                onChanged: (value) => setDialogState(() => descending = value),
              ),
              TextField(
                controller: limitController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Maximum tracks (optional)',
                  hintText: '0 for unlimited',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final value = valueController.text.trim();
                final secondValue = secondValueController.text.trim();
                limit = int.tryParse(limitController.text.trim()) ?? 0;
                if (name.isEmpty ||
                    ((rule == 'Genre' || rule == 'Artist') && value.isEmpty) ||
                    ((rule == 'Rating at least' || rule == 'Played at least') &&
                        int.tryParse(value) == null) ||
                    (secondRule != 'None' &&
                        ((secondRule == 'Genre' || secondRule == 'Artist') &&
                                secondValue.isEmpty ||
                            (secondRule == 'Rating at least' ||
                                    secondRule == 'Played at least') &&
                                int.tryParse(secondValue) == null)) ||
                    limit < 0) {
                  return;
                }
                Navigator.pop(
                  context,
                  SmartPlaylist(
                    name: name,
                    rule: rule,
                    value: value,
                    sortBy: sortBy,
                    descending: descending,
                    limit: limit,
                    matchAll: matchAll,
                    criteria: [
                      SmartCriterion(rule: rule, value: value),
                      if (secondRule != 'None')
                        SmartCriterion(rule: secondRule, value: secondValue),
                    ],
                  ),
                );
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => _smartPlaylists.add(result));
    await _saveQueue();
  }

  Future<void> _importSkin() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result.isEmpty ? null : result.first.path;
    if (path == null) return;
    try {
      final skin = ThemeSkin.fromJson(
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>,
      );
      if (!mounted) return;
      await widget.onSkinImported?.call(skin);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Imported skin: ${skin.name}')));
      }
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not import skin: $error')));
    }
  }

  Future<void> _importPlugin() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'neonamp-plugin'],
    );
    final path = result.isEmpty ? null : result.first.path;
    if (path == null) return;
    try {
      final plugin = NeonAmpPlugin.fromJson(
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>,
      );
      if (!mounted) return;
      setState(() => _plugins[plugin.id] = plugin);
      await _saveQueue();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported plugin: ${plugin.name}')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not import plugin: $error')),
      );
    }
  }

  Future<void> _showPluginManager() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Plugins'),
          content: SizedBox(
            width: 540,
            child: _plugins.isEmpty
                ? const Text('No plugins installed.')
                : ListView(
                    shrinkWrap: true,
                    children: _plugins.values
                        .map(
                          (plugin) => ListTile(
                            leading: const Icon(Icons.extension_outlined),
                            title: Text('${plugin.name} ${plugin.version}'),
                            subtitle: Text(
                              [
                                plugin.description,
                                if (plugin.capabilities.isNotEmpty)
                                  plugin.capabilities.join(', '),
                              ].where((value) => value.isNotEmpty).join(' · '),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: plugin.enabled,
                                  onChanged: (value) {
                                    if (!mounted) return;
                                    setState(
                                      () => _plugins[plugin.id] = plugin
                                          .copyWith(enabled: value),
                                    );
                                    _saveQueueSafely();
                                    setDialogState(() {});
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Remove plugin',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () {
                                    if (!mounted) return;
                                    setState(() => _plugins.remove(plugin.id));
                                    _saveQueueSafely();
                                    setDialogState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _importPlugin();
              },
              child: const Text('Import plugin'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showThemePicker() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose a skin'),
        children: [
          ...widget.skins.map(
            (theme) => RadioListTile<String>(
              value: theme.name,
              groupValue: widget.themeName,
              title: Text(theme.name),
              onChanged: (value) => Navigator.pop(context, value),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import skin package'),
            onTap: () {
              Navigator.pop(context);
              _importSkin();
            },
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    widget.onThemeChanged?.call(selected);
  }

  Future<void> _showLyrics(Track track) async {
    final lyrics = track.lyrics?.trim();
    if (lyrics == null || lyrics.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This track has no embedded lyrics.')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(track.name),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(lyrics)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _showVisualizer() async {
    final canVisualize = _dspActive && soloud.SoLoud.instance.isInitialized;
    if (canVisualize) _dspPlayer.setVisualizationEnabled(true);
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Spectrum visualizer'),
          content: SizedBox(
            width: 560,
            height: 220,
            child: canVisualize
                ? StreamBuilder<soloud.AudioVisualizationData>(
                    stream: soloud.SoLoud.instance.audioVisualizationEvents,
                    builder: (context, snapshot) => CustomPaint(
                      painter: SpectrumPainter(
                        fft: snapshot.data?.fftData,
                        active: _isPlaying,
                      ),
                    ),
                  )
                : const Center(
                    child: Text(
                      'Audio-reactive visuals are available during local playback with the equalizer enabled.',
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } finally {
      if (canVisualize) _dspPlayer.setVisualizationEnabled(false);
    }
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Crossfade tracks'),
                value: _crossfade,
                onChanged: (value) {
                  if (!mounted) return;
                  setState(() => _crossfade = value);
                  _saveQueueSafely();
                  setDialogState(() {});
                },
              ),
              if (_crossfade)
                Row(
                  children: [
                    const Text('1s'),
                    Expanded(
                      child: Slider(
                        value: _crossfadeSeconds.toDouble(),
                        min: 1,
                        max: 12,
                        divisions: 11,
                        label: '${_crossfadeSeconds}s',
                        onChanged: (value) {
                          if (!mounted) return;
                          setState(() => _crossfadeSeconds = value.round());
                          _saveQueueSafely();
                          setDialogState(() {});
                        },
                      ),
                    ),
                    const Text('12s'),
                  ],
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('ReplayGain normalization'),
                value: _replayGainEnabled,
                onChanged: (value) {
                  _runAsyncSafely(
                    _setReplayGainEnabled(value),
                    'Applying ReplayGain setting',
                  );
                  setDialogState(() {});
                },
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Keyboard controls'),
                subtitle: Text(
                  'Space: play/pause · M: mute · Ctrl+arrows: seek',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playSmartPlaylist(SmartPlaylist playlist) async {
    if (_crossfadeInProgress) return;
    final tracks = _tracksForSmartPlaylist(playlist);
    if (tracks.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No tracks match ${playlist.name}.')),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _queue
        ..clear()
        ..addAll(tracks);
      _selected = 0;
    });
    await _select(0);
  }

  Future<void> _addTrackToPlaylist(Track track) async {
    if (_playlists.isEmpty) {
      await _createPlaylist();
      if (_playlists.isEmpty) return;
    }
    if (!mounted) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist'),
        children: _playlists.keys
            .map(
              (name) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, name),
                child: Text(name),
              ),
            )
            .toList(),
      ),
    );
    if (!mounted || name == null) return;
    setState(() {
      final tracks = _playlists[name]!;
      if (!tracks.contains(track.path)) tracks.add(track.path);
    });
    await _saveQueue();
  }

  Future<void> _playPlaylist(String name) async {
    if (_crossfadeInProgress) return;
    final paths = _playlists[name];
    if (paths == null || paths.isEmpty) return;
    final tracks = paths
        .map(
          (path) => _library.firstWhere(
            (track) => track.path == path,
            orElse: () =>
                Track(path: path, name: path.split(RegExp(r'[/\\]')).last),
          ),
        )
        .toList();
    if (!mounted || tracks.isEmpty) return;
    setState(() {
      _queue
        ..clear()
        ..addAll(tracks);
      _selected = 0;
    });
    if (!mounted) return;
    await _saveQueue();
    if (mounted) await _select(0);
  }

  Future<void> _showEqualizer() async {
    final pluginPresets = <String, List<double>>{};
    for (final plugin in _plugins.values.where((plugin) => plugin.enabled)) {
      pluginPresets.addAll(plugin.equalizerPresets);
    }
    final presets = equalizerPresetNames(pluginPresets: pluginPresets);
    var dialogPreset = presets.contains(_eqPreset) ? _eqPreset : 'Flat';
    if (_eqPreset != dialogPreset) _eqPreset = dialogPreset;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Text('10-band equalizer'),
              const Spacer(),
              Switch(
                value: _equalizerEnabled,
                onChanged: _midiActive
                    ? null
                    : (value) {
                        _runAsyncSafely(
                          _setEqualizerEnabled(value),
                          'Applying equalizer setting',
                        );
                        setDialogState(() {});
                      },
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: dialogPreset,
                    decoration: const InputDecoration(labelText: 'Preset'),
                    items: presets
                        .map(
                          (preset) => DropdownMenuItem(
                            value: preset,
                            child: Text(preset),
                          ),
                        )
                        .toList(),
                    onChanged: _midiActive
                        ? null
                        : (value) {
                            if (value == null) return;
                            dialogPreset = value;
                            setState(() {
                              _eqPreset = value;
                              _eqBands.setAll(
                                0,
                                equalizerPresetBands(
                                  value,
                                  pluginPresets: pluginPresets,
                                  bandCount: _eqBands.length,
                                ),
                              );
                            });
                            if (_dspActive) {
                              _dspPlayer.applyEqualizer(
                                enabled: _equalizerEnabled,
                                bands: _eqBands,
                              );
                            }
                            _saveQueueSafely();
                            setDialogState(() {});
                          },
                  ),
                  Row(
                    children: [
                      const Text('L', style: TextStyle(color: Colors.white54)),
                      Expanded(
                        child: Slider(
                          value: _balance,
                          min: -1,
                          max: 1,
                          divisions: 40,
                          label: stereoBalanceLabel(_balance),
                          onChanged: _midiActive
                              ? null
                              : (value) {
                                  setState(() => _balance = value);
                                  _applyBalance(value);
                                  setDialogState(() {});
                                },
                          onChangeEnd: (_) => _saveQueueSafely(),
                        ),
                      ),
                      const Text('R', style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                  Text(
                    'Stereo balance · ${stereoBalanceLabel(_balance)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Crossfade between tracks'),
                    subtitle: Text('Overlap for $_crossfadeSeconds seconds'),
                    value: _crossfade,
                    onChanged: (value) {
                      setState(() => _crossfade = value);
                      _saveQueueSafely();
                      setDialogState(() {});
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('ReplayGain normalization'),
                    subtitle: const Text(
                      'Use embedded track or album gain tags when available',
                    ),
                    value: _replayGainEnabled,
                    onChanged: (value) {
                      _runAsyncSafely(
                        _setReplayGainEnabled(value),
                        'Applying ReplayGain setting',
                      );
                      setDialogState(() {});
                    },
                  ),
                  if (_crossfade)
                    Row(
                      children: [
                        const Text(
                          '1s',
                          style: TextStyle(color: Colors.white38),
                        ),
                        Expanded(
                          child: Slider(
                            value: _crossfadeSeconds.toDouble(),
                            min: 1,
                            max: 12,
                            divisions: 11,
                            label: '${_crossfadeSeconds}s',
                            onChanged: (value) {
                              setState(() => _crossfadeSeconds = value.round());
                              _saveQueueSafely();
                              setDialogState(() {});
                            },
                          ),
                        ),
                        const Text(
                          '12s',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 180,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: List.generate(
                        _eqBands.length,
                        (index) => Expanded(
                          child: Column(
                            children: [
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: Slider(
                                    value: _eqBands[index],
                                    min: -12,
                                    max: 12,
                                    onChanged: _equalizerEnabled
                                        ? (value) {
                                            setState(
                                              () => _eqBands[index] = value,
                                            );
                                            if (_dspActive) {
                                              _dspPlayer.applyEqualizer(
                                                enabled: true,
                                                bands: _eqBands,
                                              );
                                            }
                                            setDialogState(() {});
                                          }
                                        : null,
                                    onChangeEnd: (_) => _saveQueueSafely(),
                                  ),
                                ),
                              ),
                              Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white38,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    await _saveQueue();
  }

  Future<void> _showPlaybackSpeed() async {
    var selected = _playbackSpeed;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Playback speed'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_casting)
                const Text(
                  'Speed control is unavailable while casting to this player.',
                  textAlign: TextAlign.center,
                ),
              Text('${selected.toStringAsFixed(2)}×'),
              Slider(
                value: selected,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: '${selected.toStringAsFixed(2)}×',
                onChanged: _casting
                    ? null
                    : (value) {
                        selected = value;
                        setDialogState(() {});
                      },
                onChangeEnd: _casting
                    ? null
                    : (value) => _runAsyncSafely(
                        _setPlaybackSpeed(value),
                        'Applying playback speed',
                      ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final speed in [0.5, 1.0, 1.25, 1.5, 2.0])
                    OutlinedButton(
                      onPressed: _casting
                          ? null
                          : () {
                              selected = speed;
                              setDialogState(() {});
                              _runAsyncSafely(
                                _setPlaybackSpeed(speed),
                                'Applying playback speed',
                              );
                            },
                      child: Text('${speed}×'),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showPlayerLayout() async {
    final draft = List<String>.from(_playerControls);
    var resetToDefault = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Customize player controls'),
          content: SizedBox(
            width: 400,
            height: 430,
            child: Column(
              children: [
                const Text(
                  'Drag to reorder. Keep Play / pause in the bar and add the actions you use.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ReorderableListView(
                    onReorderItem: (oldIndex, newIndex) {
                      final control = draft.removeAt(oldIndex);
                      draft.insert(newIndex, control);
                      resetToDefault = false;
                      setDialogState(() {});
                    },
                    children: [
                      for (var index = 0; index < draft.length; index++)
                        ListTile(
                          key: ValueKey('${draft[index]}-$index'),
                          dense: true,
                          leading: ReorderableDragStartListener(
                            index: index,
                            child: const Icon(
                              Icons.drag_handle,
                              color: Colors.white38,
                            ),
                          ),
                          title: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: draft[index],
                              items: [
                                for (final entry in playerControlLabels.entries)
                                  if (entry.key == draft[index] ||
                                      !draft.contains(entry.key))
                                    DropdownMenuItem(
                                      value: entry.key,
                                      child: Text(
                                        entry.value,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                              ],
                              onChanged: (value) {
                                if (value == null) return;
                                draft[index] = value;
                                resetToDefault = false;
                                setDialogState(() {});
                              },
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: 'Remove control',
                            onPressed: draft[index] == 'playPause'
                                ? null
                                : () {
                                    draft.removeAt(index);
                                    resetToDefault = false;
                                    setDialogState(() {});
                                  },
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: null,
                  hint: const Text('Add a control'),
                  items: [
                    for (final entry in playerControlLabels.entries)
                      if (!draft.contains(entry.key))
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    draft.add(value);
                    resetToDefault = false;
                    setDialogState(() {});
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                draft
                  ..clear()
                  ..addAll(defaultPlayerControls);
                resetToDefault = true;
                setDialogState(() {});
              },
              child: const Text('Reset'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save layout'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || saved != true) return;
    setState(() {
      _playerControls = normalizePlayerControls(draft);
      _playerLayoutCustomized = !resetToDefault;
    });
    await _saveQueue();
  }

  Widget _playerControl(String control) {
    final selectedColor = const Color(0xffef4bff);
    switch (control) {
      case 'previous':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: _previous,
          icon: const Icon(Icons.skip_previous_rounded),
          color: Colors.white70,
        );
      case 'rewind15':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: () => _skipBy(const Duration(seconds: -15)),
          icon: const Icon(Icons.fast_rewind_rounded),
          color: Colors.white70,
        );
      case 'playPause':
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xffef4bff),
          ),
          child: IconButton(
            tooltip: _isPlaying ? 'Pause' : 'Play',
            onPressed: _togglePlay,
            icon: Icon(
              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
            iconSize: 28,
            color: Colors.white,
          ),
        );
      case 'forward15':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: () => _skipBy(const Duration(seconds: 15)),
          icon: const Icon(Icons.fast_forward_rounded),
          color: Colors.white70,
        );
      case 'next':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: _next,
          icon: const Icon(Icons.skip_next_rounded),
          color: Colors.white70,
        );
      case 'shuffle':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: () => setState(() => _shuffle = !_shuffle),
          icon: const Icon(Icons.shuffle_rounded),
          color: _shuffle ? selectedColor : Colors.white38,
        );
      case 'repeat':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: () => setState(() {
            if (!_repeat && !_repeatOne) {
              _repeat = true;
            } else if (_repeat) {
              _repeat = false;
              _repeatOne = true;
            } else {
              _repeatOne = false;
            }
          }),
          icon: Icon(
            _repeatOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          ),
          color: (_repeat || _repeatOne) ? selectedColor : Colors.white38,
        );
      case 'equalizer':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: _showEqualizer,
          icon: const Icon(Icons.equalizer_rounded),
          color: _equalizerEnabled ? selectedColor : Colors.white70,
        );
      case 'speed':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: _showPlaybackSpeed,
          icon: const Icon(Icons.speed_rounded),
          color: Colors.white70,
        );
      case 'sleep':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: _showSleepTimer,
          icon: const Icon(Icons.bedtime_outlined),
          color: _sleepDeadline == null ? Colors.white70 : selectedColor,
        );
      case 'queue':
        return IconButton(
          tooltip: playerControlLabels[control],
          onPressed: () => setState(() => _activeView = 'queue'),
          icon: const Icon(Icons.queue_music_rounded),
          color: Colors.white70,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    final crossfadeAudioPlayer = _crossfadeAudioPlayer;
    final crossfadeDspPlayer = _crossfadeDspPlayer;
    _crossfadeInProgress = false;
    if (crossfadeAudioPlayer != null) {
      _runAsyncSafely(
        crossfadeAudioPlayer.dispose(),
        'Disposing crossfade player',
      );
    }
    if (crossfadeDspPlayer != null) {
      _runAsyncSafely(
        crossfadeDspPlayer.dispose(),
        'Disposing DSP crossfade player',
      );
    }
    _runAsyncSafely(_dlnaCast.dispose(), 'Disposing DLNA cast');
    _castPositionTimer?.cancel();
    _sleepTimer?.cancel();
    _resumeSaveTimer?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _dspPositionSub?.cancel();
    _dspDurationSub?.cancel();
    _dspStateSub?.cancel();
    _dspCompleteSub?.cancel();
    _midiPositionSub?.cancel();
    _midiDurationSub?.cancel();
    _midiStateSub?.cancel();
    _midiCompleteSub?.cancel();
    final audioHandler = _audioHandler;
    if (audioHandler != null) {
      _runAsyncSafely(audioHandler.close(), 'Closing audio service');
    }
    if (Platform.isWindows) {
      const MethodChannel('neonamp/system_controls').setMethodCallHandler(null);
    }
    _searchController.dispose();
    _pulse.dispose();
    _player.dispose();
    _runAsyncSafely(_midiPlayer.dispose(), 'Disposing MIDI player');
    _runAsyncSafely(_dspPlayer.dispose(), 'Disposing DSP player');
    super.dispose();
  }

  String _time(Duration value) =>
      '${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  String _ratingLabel(int rating) => '${'★' * rating}${'☆' * (5 - rating)}';

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.space): _TogglePlayIntent(),
      SingleActivator(LogicalKeyboardKey.arrowRight): _NextTrackIntent(),
      SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousTrackIntent(),
      SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
          _SeekIntent(Duration(seconds: 10)),
      SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): _SeekIntent(
        Duration(seconds: -10),
      ),
      SingleActivator(LogicalKeyboardKey.keyM): _MuteIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _TogglePlayIntent: CallbackAction<_TogglePlayIntent>(
          onInvoke: (_) {
            _togglePlay();
            return null;
          },
        ),
        _NextTrackIntent: CallbackAction<_NextTrackIntent>(
          onInvoke: (_) {
            _next();
            return null;
          },
        ),
        _PreviousTrackIntent: CallbackAction<_PreviousTrackIntent>(
          onInvoke: (_) {
            _previous();
            return null;
          },
        ),
        _SeekIntent: CallbackAction<_SeekIntent>(
          onInvoke: (intent) {
            final target = _position + intent.amount;
            _seekCurrent(
              target < Duration.zero
                  ? Duration.zero
                  : (target > _duration ? _duration : target),
            );
            return null;
          },
        ),
        _MuteIntent: CallbackAction<_MuteIntent>(
          onInvoke: (_) {
            final muted = _volume > 0;
            final nextVolume = muted ? 0.0 : 0.82;
            setState(() => _volume = nextVolume);
            if (_casting) {
              _runAsyncSafely(
                _dlnaCast.setVolume(_volumeFor(_current)),
                'Setting cast volume',
              );
            } else if (_dspActive) {
              _runAsyncSafely(
                _dspPlayer.setVolume(_volumeFor(_current)),
                'Setting DSP volume',
              );
            } else {
              _runAsyncSafely(
                _player.setVolume(_volumeFor(_current)),
                'Setting volume',
              );
            }
            _saveQueueSafely();
            return null;
          },
        ),
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 600;
              return Column(
                children: [
                  _topBar(compact),
                  Expanded(child: compact ? _compactLayout() : _wideLayout()),
                  _bottomPlayer(),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _topBar(bool compact) => Padding(
    padding: EdgeInsets.fromLTRB(
      compact ? 12 : 24,
      compact ? 8 : 18,
      compact ? 8 : 24,
      compact ? 4 : 12,
    ),
    child: Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xffef4bff),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(color: Color(0x66ef4bff), blurRadius: 18),
            ],
          ),
          child: const Icon(Icons.graphic_eq, color: Colors.white),
        ),
        const SizedBox(width: 12),
        const Text(
          'NEONAMP',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 2.6,
            fontSize: 18,
          ),
        ),
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 1600) ...[
          _topAction(Icons.equalizer, 'Visuals'),
          const SizedBox(width: 8),
          _topAction(Icons.settings_outlined, 'Settings'),
          const SizedBox(width: 16),
        ],
        if (compact)
          IconButton.filled(
            tooltip: 'Add music',
            onPressed: _addFiles,
            icon: const Icon(Icons.add),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xffef4bff),
              foregroundColor: Colors.white,
            ),
          )
        else
          FilledButton.icon(
            onPressed: _addFiles,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add music'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffef4bff),
              foregroundColor: Colors.white,
            ),
          ),
        if (MediaQuery.sizeOf(context).width >= 1600)
          IconButton(
            tooltip: 'Add folder',
            onPressed: _addFolder,
            icon: const Icon(
              Icons.create_new_folder_outlined,
              color: Colors.white60,
            ),
          ),
        if (MediaQuery.sizeOf(context).width >= 1600)
          IconButton(
            tooltip: 'Import audio CD',
            onPressed: _importAudioCd,
            icon: const Icon(Icons.album_outlined, color: Colors.white60),
          ),
        if (MediaQuery.sizeOf(context).width >= 1600)
          IconButton(
            tooltip: 'Sleep timer',
            onPressed: _showSleepTimer,
            icon: Icon(
              Icons.bedtime_outlined,
              color: _sleepDeadline == null
                  ? Colors.white60
                  : const Color(0xffef4bff),
            ),
          ),
        if (!compact)
          IconButton(
            tooltip: 'Rescan library folders',
            onPressed: _rescanFolders,
            icon: const Icon(Icons.refresh, color: Colors.white60),
          ),
        if (MediaQuery.sizeOf(context).width >= 1600) ...[
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Add stream URL',
            onPressed: _addStream,
            icon: const Icon(Icons.link, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Find internet radio',
            onPressed: _searchRadioDirectory,
            icon: const Icon(Icons.radio, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Subscribe to podcast RSS',
            onPressed: _addPodcastFeed,
            icon: const Icon(Icons.podcasts, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Refresh podcasts',
            onPressed: _refreshPodcasts,
            icon: const Icon(Icons.podcasts_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Import podcast subscriptions (OPML)',
            onPressed: _importPodcastSubscriptions,
            icon: const Icon(Icons.file_open_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Export podcast subscriptions (OPML)',
            onPressed: _exportPodcastSubscriptions,
            icon: const Icon(
              Icons.file_download_outlined,
              color: Colors.white60,
            ),
          ),
          IconButton(
            tooltip: 'Manage podcast subscriptions',
            onPressed: _managePodcastSubscriptions,
            icon: const Icon(
              Icons.manage_accounts_outlined,
              color: Colors.white60,
            ),
          ),
          IconButton(
            tooltip: 'Equalizer',
            onPressed: _showEqualizer,
            icon: Icon(
              Icons.equalizer,
              color: _equalizerEnabled
                  ? const Color(0xffef4bff)
                  : Colors.white60,
            ),
          ),
          IconButton(
            tooltip: 'Playback speed',
            onPressed: _showPlaybackSpeed,
            icon: const Icon(Icons.speed, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Choose skin',
            onPressed: _showThemePicker,
            icon: const Icon(Icons.palette_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Import skin package',
            onPressed: _importSkin,
            icon: const Icon(Icons.file_upload_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Manage plugins',
            onPressed: _showPluginManager,
            icon: Icon(
              Icons.extension_outlined,
              color: _plugins.values.any((plugin) => plugin.enabled)
                  ? const Color(0xffef4bff)
                  : Colors.white60,
            ),
          ),
          IconButton(
            tooltip: 'Export M3U playlist',
            onPressed: _exportPlaylist,
            icon: const Icon(Icons.ios_share, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Sync music to device folder',
            onPressed: _syncToDeviceFolder,
            icon: const Icon(Icons.sync, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Export PLS playlist',
            onPressed: _exportPlsPlaylist,
            icon: const Icon(Icons.radio, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Export Winamp B4S playlist',
            onPressed: _exportB4sPlaylist,
            icon: const Icon(Icons.queue_music, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Export WPL playlist',
            onPressed: _exportWplPlaylist,
            icon: const Icon(Icons.library_music, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Export ASX playlist',
            onPressed: _exportAsxPlaylist,
            icon: const Icon(Icons.playlist_play, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Import M3U, PLS, B4S, WPL, or ASX playlist',
            onPressed: _importPlaylist,
            icon: const Icon(Icons.file_open_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Import iTunes XML library',
            onPressed: _importItunesLibrary,
            icon: const Icon(Icons.library_add_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Export iTunes XML library',
            onPressed: _exportItunesLibrary,
            icon: const Icon(
              Icons.library_books_outlined,
              color: Colors.white60,
            ),
          ),
          IconButton(
            tooltip: 'Import CUE sheet',
            onPressed: _importCueSheet,
            icon: const Icon(Icons.album_outlined, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Play videos',
            onPressed: _openVideoPicker,
            icon: const Icon(
              Icons.video_library_outlined,
              color: Colors.white60,
            ),
          ),
        ] else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white60),
            onSelected: (value) {
              if (value == 'folder') _addFolder();
              if (value == 'visuals') _showVisualizer();
              if (value == 'settings') _showSettings();
              if (value == 'rescan') _rescanFolders();
              if (value == 'import') _importPlaylist();
              if (value == 'importItunes') _importItunesLibrary();
              if (value == 'exportItunes') _exportItunesLibrary();
              if (value == 'importCue') _importCueSheet();
              if (value == 'stream') _addStream();
              if (value == 'radio') _searchRadioDirectory();
              if (value == 'podcast') _addPodcastFeed();
              if (value == 'refreshPodcasts') _refreshPodcasts();
              if (value == 'importPodcasts') _importPodcastSubscriptions();
              if (value == 'exportPodcasts') _exportPodcastSubscriptions();
              if (value == 'managePodcasts') _managePodcastSubscriptions();
              if (value == 'eq') _showEqualizer();
              if (value == 'speed') _showPlaybackSpeed();
              if (value == 'layout') _showPlayerLayout();
              if (value == 'theme') _showThemePicker();
              if (value == 'importSkin') _importSkin();
              if (value == 'plugins') _showPluginManager();
              if (value == 'export') _exportPlaylist();
              if (value == 'sync') _syncToDeviceFolder();
              if (value == 'cd') _importAudioCd();
              if (value == 'sleep') _showSleepTimer();
              if (value == 'exportPls') _exportPlsPlaylist();
              if (value == 'exportB4s') _exportB4sPlaylist();
              if (value == 'exportWpl') _exportWplPlaylist();
              if (value == 'exportAsx') _exportAsxPlaylist();
              if (value == 'video') _openVideoPicker();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'visuals', child: Text('Visuals')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'folder', child: Text('Add folder')),
              PopupMenuItem(
                value: 'rescan',
                child: Text('Rescan library folders'),
              ),
              PopupMenuItem(
                value: 'import',
                child: Text('Import M3U, PLS, B4S, WPL, or ASX playlist'),
              ),
              PopupMenuItem(
                value: 'importItunes',
                child: Text('Import iTunes XML library'),
              ),
              PopupMenuItem(
                value: 'exportItunes',
                child: Text('Export iTunes XML library'),
              ),
              PopupMenuItem(
                value: 'importCue',
                child: Text('Import CUE sheet'),
              ),
              PopupMenuItem(value: 'stream', child: Text('Add stream URL')),
              PopupMenuItem(value: 'radio', child: Text('Find internet radio')),
              PopupMenuItem(
                value: 'podcast',
                child: Text('Subscribe to podcast RSS'),
              ),
              PopupMenuItem(
                value: 'refreshPodcasts',
                child: Text('Refresh podcasts'),
              ),
              PopupMenuItem(
                value: 'importPodcasts',
                child: Text('Import podcast subscriptions (OPML)'),
              ),
              PopupMenuItem(
                value: 'exportPodcasts',
                child: Text('Export podcast subscriptions (OPML)'),
              ),
              PopupMenuItem(
                value: 'managePodcasts',
                child: Text('Manage podcast subscriptions'),
              ),
              PopupMenuItem(value: 'eq', child: Text('Equalizer')),
              PopupMenuItem(value: 'speed', child: Text('Playback speed')),
              PopupMenuItem(
                value: 'layout',
                child: Text('Customize player controls'),
              ),
              PopupMenuItem(value: 'theme', child: Text('Choose skin')),
              PopupMenuItem(
                value: 'importSkin',
                child: Text('Import skin package'),
              ),
              PopupMenuItem(value: 'plugins', child: Text('Manage plugins')),
              PopupMenuItem(
                value: 'export',
                child: Text('Export M3U playlist'),
              ),
              PopupMenuItem(
                value: 'sync',
                child: Text('Sync music to device folder'),
              ),
              if (!Platform.isAndroid)
                const PopupMenuItem(
                  value: 'cd',
                  child: Text('Import audio CD'),
                ),
              PopupMenuItem(value: 'sleep', child: Text('Sleep timer')),
              PopupMenuItem(
                value: 'exportPls',
                child: Text('Export PLS playlist'),
              ),
              PopupMenuItem(
                value: 'exportB4s',
                child: Text('Export Winamp B4S playlist'),
              ),
              PopupMenuItem(
                value: 'exportWpl',
                child: Text('Export WPL playlist'),
              ),
              PopupMenuItem(
                value: 'exportAsx',
                child: Text('Export ASX playlist'),
              ),
              PopupMenuItem(value: 'video', child: Text('Play videos')),
            ],
          ),
      ],
    ),
  );

  Widget _topAction(IconData icon, String label) => TextButton.icon(
    onPressed: label == 'Visuals' ? _showVisualizer : _showSettings,
    icon: Icon(icon, size: 18, color: Colors.white60),
    label: Text(label, style: const TextStyle(color: Colors.white60)),
  );
  Widget _wideLayout() => Row(
    children: [
      SizedBox(width: 330, child: _queuePanel()),
      Expanded(child: _heroPanel()),
    ],
  );
  Widget _compactLayout() => Column(
    children: [
      SizedBox(height: 104, child: _heroPanel(compact: true)),
      Expanded(child: _queuePanel()),
    ],
  );

  Widget _queuePanel() => Container(
    margin: MediaQuery.sizeOf(context).width < 600
        ? const EdgeInsets.fromLTRB(8, 4, 8, 6)
        : const EdgeInsets.fromLTRB(24, 8, 12, 12),
    decoration: BoxDecoration(
      color: const Color(0xff11131c),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 12, 8),
          child: Row(
            children: [
              const Text(
                'QUEUE',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                '${_queue.length} tracks',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
              if (_queue.isNotEmpty)
                IconButton(
                  onPressed: _clearQueue,
                  icon: const Icon(Icons.clear_all, size: 18),
                  color: Colors.white38,
                  tooltip: 'Clear queue',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _viewButton('queue', 'Queue', Icons.queue_music),
                _viewButton('library', 'Library', Icons.library_music),
                _viewButton('bookmarks', 'Bookmarks', Icons.bookmark_outline),
                _viewButton('playlists', 'Playlists', Icons.playlist_play),
                _viewButton('history', 'History', Icons.history),
              ],
            ),
          ),
        ),
        if (_activeView == 'library')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Search artist, album, genre…',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _libraryFilter,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'All', child: Text('All')),
                    DropdownMenuItem(
                      value: 'Favorites',
                      child: Text('Favorites'),
                    ),
                    DropdownMenuItem(
                      value: 'Top rated',
                      child: Text('Top rated'),
                    ),
                    DropdownMenuItem(
                      value: 'Most played',
                      child: Text('Most played'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _libraryFilter = value);
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: 'Sort library',
                  icon: const Icon(Icons.sort, size: 19),
                  onSelected: (value) {
                    setState(() => _librarySort = value);
                    _saveQueueSafely();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'Added',
                      child: Text('Recently added'),
                    ),
                    PopupMenuItem(value: 'Title', child: Text('Title')),
                    PopupMenuItem(value: 'Artist', child: Text('Artist')),
                    PopupMenuItem(value: 'Album', child: Text('Album')),
                    PopupMenuItem(value: 'Rating', child: Text('Rating')),
                    PopupMenuItem(
                      value: 'Play count',
                      child: Text('Play count'),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: _librarySortDescending
                      ? 'Sort ascending'
                      : 'Sort descending',
                  icon: Icon(
                    _librarySortDescending
                        ? Icons.arrow_downward
                        : Icons.arrow_upward,
                    size: 17,
                  ),
                  onPressed: () {
                    setState(
                      () => _librarySortDescending = !_librarySortDescending,
                    );
                    _saveQueueSafely();
                  },
                ),
              ],
            ),
          ),
        if (_activeView == 'library' && _selectedLibraryPaths.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text(
                  '${_selectedLibraryPaths.length} selected',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _editSelectedTracks,
                  icon: const Icon(Icons.edit_note, size: 17),
                  label: const Text('Edit metadata'),
                ),
                IconButton(
                  tooltip: 'Clear selection',
                  onPressed: () => setState(_selectedLibraryPaths.clear),
                  icon: const Icon(Icons.close, size: 17),
                ),
              ],
            ),
          ),
        Expanded(
          child: _activeView == 'library'
              ? _libraryView()
              : _activeView == 'bookmarks'
              ? _bookmarksView()
              : _activeView == 'playlists'
              ? _playlistView()
              : _activeView == 'history'
              ? _historyView()
              : _queue.isEmpty
              ? _emptyQueue()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: _queue.length,
                  onReorderItem: _reorderQueue,
                  itemBuilder: (_, index) => _queueItem(index),
                ),
        ),
      ],
    ),
  );

  Widget _viewButton(String view, String label, IconData icon) =>
      TextButton.icon(
        onPressed: () => setState(() => _activeView = view),
        icon: Icon(
          icon,
          size: 15,
          color: _activeView == view ? const Color(0xffef4bff) : Colors.white38,
        ),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: _activeView == view ? Colors.white : Colors.white38,
          ),
        ),
      );

  Widget _libraryView() {
    final tracks = _visibleLibrary;
    if (tracks.isEmpty) return _emptyQueue();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: tracks.length,
      itemBuilder: (_, index) {
        final track = tracks[index];
        return ListTile(
          dense: true,
          leading: Checkbox(
            value: _selectedLibraryPaths.contains(track.path),
            onChanged: (_) => _toggleLibrarySelection(track),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          title: Text(
            track.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          subtitle: Text(
            '${track.artist} · ${track.album} · ${_ratingLabel(track.rating)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: _isBookmarked(track)
                    ? 'Remove bookmark'
                    : 'Add bookmark',
                icon: Icon(
                  _isBookmarked(track) ? Icons.bookmark : Icons.bookmark_border,
                  size: 17,
                  color: _isBookmarked(track)
                      ? const Color(0xffef4bff)
                      : Colors.white30,
                ),
                onPressed: () => _toggleBookmark(track),
              ),
              IconButton(
                icon: Icon(
                  track.favorite ? Icons.favorite : Icons.favorite_border,
                  size: 17,
                  color: track.favorite
                      ? const Color(0xffef4bff)
                      : Colors.white30,
                ),
                onPressed: () => _toggleFavorite(track),
              ),
              IconButton(
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 17,
                  color: Colors.white30,
                ),
                onPressed: () => _editTrack(track),
              ),
              IconButton(
                tooltip: 'Replace cover art',
                icon: const Icon(
                  Icons.image_outlined,
                  size: 17,
                  color: Colors.white30,
                ),
                onPressed: () => _replaceArtwork(track),
              ),
              if (!isUriMediaPath(track.path))
                IconButton(
                  tooltip: 'Convert to M4A',
                  icon: const Icon(
                    Icons.transform,
                    size: 17,
                    color: Colors.white30,
                  ),
                  onPressed: () => _convertTrackToM4a(track),
                ),
              if (track.lyrics?.trim().isNotEmpty == true)
                IconButton(
                  tooltip: 'View lyrics',
                  icon: const Icon(
                    Icons.lyrics_outlined,
                    size: 17,
                    color: Colors.white30,
                  ),
                  onPressed: () => _showLyrics(track),
                ),
              IconButton(
                icon: const Icon(
                  Icons.playlist_add,
                  size: 17,
                  color: Colors.white30,
                ),
                onPressed: () => _addTrackToPlaylist(track),
              ),
              if (track.album == 'Podcast' && isRemoteMediaPath(track.path))
                IconButton(
                  tooltip: 'Download episode',
                  icon: const Icon(
                    Icons.download_outlined,
                    size: 17,
                    color: Colors.white30,
                  ),
                  onPressed: () => _downloadPodcastEpisode(track),
                ),
            ],
          ),
          onTap: () {
            setState(() {
              _queue.add(track);
              _selected = _queue.length - 1;
            });
            _select(_selected);
          },
        );
      },
    );
  }

  Widget _bookmarksView() {
    if (_bookmarks.isEmpty) return _emptyQueue();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _bookmarks.length,
      itemBuilder: (_, index) {
        final track = _bookmarks[index];
        return ListTile(
          key: ValueKey(track.identityKey),
          dense: true,
          leading: const Icon(Icons.bookmark, color: Color(0xffef4bff)),
          title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${track.artist} · ${track.path}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          trailing: IconButton(
            tooltip: 'Remove bookmark',
            icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
            onPressed: () => _toggleBookmark(track),
          ),
          onTap: () => _playBookmark(track),
        );
      },
    );
  }

  Widget _historyView() {
    if (_playHistory.isEmpty) return _emptyQueue();
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              setState(_playHistory.clear);
              await _saveQueue();
            },
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: const Text('Clear history'),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: _playHistory.length,
            itemBuilder: (_, index) {
              final identity = _playHistory[index];
              final track = _queue.firstWhere(
                (item) => item.identityKey == identity,
                orElse: () => _library.firstWhere(
                  (item) => item.identityKey == identity,
                  orElse: () {
                    try {
                      final cue = jsonDecode(identity) as List;
                      final path = cue[0] as String;
                      final number = (cue[3] as num?)?.toInt();
                      return Track(
                        path: path,
                        name:
                            '${path.split(RegExp(r'[/\\]')).last} · ${number ?? ''}',
                        trackNumber: number,
                        cueStartMs: (cue[1] as num?)?.toInt(),
                        cueEndMs: (cue[2] as num?)?.toInt(),
                      );
                    } on Object {
                      return Track(
                        path: identity,
                        name: identity.split(RegExp(r'[/\\]')).last,
                      );
                    }
                  },
                ),
              );
              return ListTile(
                dense: true,
                leading: const Icon(Icons.history, size: 18),
                title: Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${track.artist} · ${track.album}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
                onTap: () {
                  setState(() {
                    _queue.add(track);
                    _selected = _queue.length - 1;
                  });
                  _select(_selected);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _playlistView() => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            onPressed: _createPlaylist,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New playlist'),
          ),
          TextButton.icon(
            onPressed: _createSmartPlaylist,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('New smart playlist'),
          ),
        ],
      ),
      Expanded(
        child: _playlists.isEmpty && _smartPlaylists.isEmpty
            ? _emptyQueue()
            : ListView(
                children: [
                  if (_playlists.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 8, 18, 2),
                      child: Text(
                        'PLAYLISTS',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                  ..._playlists.keys.map(
                    (name) => ListTile(
                      leading: const Icon(
                        Icons.playlist_play,
                        color: Color(0xffef4bff),
                      ),
                      title: Text(name),
                      subtitle: Text(
                        '${_playlists[name]!.length} tracks',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      onTap: () => _playPlaylist(name),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Playlist actions',
                        onSelected: (action) {
                          switch (action) {
                            case 'edit':
                              _editPlaylist(name);
                              break;
                            case 'rename':
                              _renamePlaylist(name);
                              break;
                            case 'delete':
                              _deletePlaylist(name);
                              break;
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'edit',
                            child: Text('Edit tracks'),
                          ),
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                  ),
                  if (_smartPlaylists.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 16, 18, 2),
                      child: Text(
                        'SMART PLAYLISTS',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                  ..._smartPlaylists.asMap().entries.map((entry) {
                    final index = entry.key;
                    final playlist = entry.value;
                    final count = _tracksForSmartPlaylist(playlist).length;
                    return ListTile(
                      leading: const Icon(
                        Icons.auto_awesome,
                        color: Color(0xffef4bff),
                      ),
                      title: Text(playlist.name),
                      subtitle: Text(
                        '${playlist.rule}${playlist.value.isEmpty ? '' : ': ${playlist.value}'} · $count tracks',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: 'Delete smart playlist',
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Colors.white30,
                        ),
                        onPressed: () async {
                          setState(() => _smartPlaylists.removeAt(index));
                          await _saveQueue();
                        },
                      ),
                      onTap: () => _playSmartPlaylist(playlist),
                    );
                  }),
                ],
              ),
      ),
    ],
  );

  Widget _emptyQueue() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_music_outlined, color: Colors.white24, size: 42),
          const SizedBox(height: 14),
          const Text(
            'Your library is quiet.',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Drop in a few tracks\nto get the party started.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, height: 1.4, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _queueItem(int index) {
    final track = _queue[index];
    final selected = index == _selected;
    return KeyedSubtree(
      key: ValueKey(track.identityKey),
      child: InkWell(
        onTap: () => _select(index),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xff272034) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xffef4bff)
                      : const Color(0xff222532),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  selected && _isPlaying ? Icons.graphic_eq : Icons.music_note,
                  size: 17,
                  color: selected ? Colors.white : Colors.white38,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      track.artist,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _isBookmarked(track)
                    ? 'Remove bookmark'
                    : 'Add bookmark',
                onPressed: () => _toggleBookmark(track),
                icon: Icon(
                  _isBookmarked(track) ? Icons.bookmark : Icons.bookmark_border,
                  size: 16,
                  color: _isBookmarked(track)
                      ? const Color(0xffef4bff)
                      : Colors.white38,
                ),
              ),
              IconButton(
                onPressed: () => _remove(index),
                icon: const Icon(Icons.close, size: 16, color: Colors.white24),
                tooltip: 'Remove',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroPanel({bool compact = false}) => AnimatedBuilder(
    animation: _pulse,
    builder: (_, __) => Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(8, 4, 8, 4)
          : const EdgeInsets.fromLTRB(12, 8, 24, 12),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xff151122), Color(0xff0c1720)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x33ef4bff)),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -80,
              right: -80,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xffef4bff)
                          .withOpacity(.09 + _pulse.value * .03),
                      blurRadius: 100,
                      spreadRadius: 30,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(compact ? 12 : 32),
              child: compact
                  ? Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _current?.artwork != null
                              ? Image.memory(
                                  _current!.artwork!,
                                  width: 58,
                                  height: 58,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.graphic_eq,
                                    size: 42,
                                    color: Colors.white24,
                                  ),
                                )
                              : const SizedBox(
                                  width: 58,
                                  height: 58,
                                  child: Icon(
                                    Icons.graphic_eq,
                                    size: 42,
                                    color: Colors.white24,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'NOW PLAYING',
                                style: TextStyle(
                                  color: Color(0xffef4bff),
                                  fontSize: 9,
                                  letterSpacing: 1.6,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _current?.name ?? 'Nothing queued',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                _current?.artist ?? 'Add local music to begin',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          _isPlaying ? Icons.waves : Icons.pause_circle_outline,
                          color: Colors.white30,
                          size: 20,
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'NOW PLAYING',
                              style: TextStyle(
                                color: Color(0xffef4bff),
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              _isPlaying
                                  ? Icons.waves
                                  : Icons.pause_circle_outline,
                              color: Colors.white30,
                              size: 20,
                            ),
                          ],
                        ),
                        const Spacer(),
                        Center(
                          child: _current?.artwork != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Image.memory(
                                    _current!.artwork!,
                                    width: 180,
                                    height: 180,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(
                                      Icons.graphic_eq,
                                      size: 80,
                                      color: Colors.white24,
                                    ),
                                  ),
                                )
                              : const Icon(
                                  Icons.graphic_eq,
                                  size: 80,
                                  color: Colors.white24,
                                ),
                        ),
                        const Spacer(),
                        Text(
                          _current?.name ?? 'Nothing queued',
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.7,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _current?.artist ?? 'Add local music to begin',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _bottomPlayer() => Container(
    padding: MediaQuery.sizeOf(context).width < 600
        ? const EdgeInsets.fromLTRB(8, 2, 8, 4)
        : const EdgeInsets.fromLTRB(24, 10, 24, 18),
    decoration: const BoxDecoration(
      color: Color(0xff0c0d14),
      border: Border(top: BorderSide(color: Colors.white10)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Text(
              _time(_position),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            Expanded(
              child: Slider(
                value: _duration.inMilliseconds == 0
                    ? 0
                    : (_position.inMilliseconds / _duration.inMilliseconds)
                          .clamp(0.0, 1.0),
                onChanged: _duration.inMilliseconds == 0
                    ? null
                    : (value) => _seekCurrent(
                        Duration(
                          milliseconds: (_duration.inMilliseconds * value)
                              .round(),
                        ),
                      ),
                activeColor: const Color(0xffef4bff),
                inactiveColor: Colors.white12,
              ),
            ),
            Text(
              _time(_duration),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            IconButton(
              tooltip: _casting
                  ? 'Casting to ${_dlnaCast.rendererName ?? 'device'}'
                  : 'Cast to a network player',
              onPressed: _showCastDevices,
              icon: Icon(
                _casting ? Icons.cast_connected_rounded : Icons.cast_rounded,
                size: 18,
              ),
              color: _casting ? const Color(0xffef4bff) : Colors.white54,
            ),
            IconButton(
              tooltip: 'Customize player controls',
              onPressed: _showPlayerLayout,
              icon: const Icon(Icons.tune_rounded, size: 18),
              color: Colors.white54,
            ),
          ],
        ),
        Row(
          children: [
            if (_playerLayoutCustomized) ...[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: _playerControls.map(_playerControl).toList(),
                  ),
                ),
              ),
              if (MediaQuery.sizeOf(context).width >= 600) ...[
                const Icon(
                  Icons.volume_up_rounded,
                  color: Colors.white38,
                  size: 18,
                ),
                SizedBox(
                  width: 110,
                  child: Slider(
                    value: _volume,
                    onChanged: _midiActive
                        ? null
                        : (value) {
                            setState(() => _volume = value);
                            if (_casting) {
                              _runAsyncSafely(
                                _dlnaCast.setVolume(_volumeFor(_current)),
                                'Setting cast volume',
                              );
                            } else if (_dspActive) {
                              _runAsyncSafely(
                                _dspPlayer.setVolume(_volumeFor(_current)),
                                'Setting DSP volume',
                              );
                            } else {
                              _runAsyncSafely(
                                _player.setVolume(_volumeFor(_current)),
                                'Setting volume',
                              );
                            }
                          },
                    activeColor: Colors.white70,
                    inactiveColor: Colors.white12,
                  ),
                ),
              ],
            ] else ...[
              IconButton(
                tooltip: 'Rewind 15 seconds',
                onPressed: () => _skipBy(const Duration(seconds: -15)),
                icon: const Icon(Icons.fast_rewind_rounded),
                color: Colors.white70,
              ),
              IconButton(
                onPressed: _previous,
                icon: const Icon(Icons.skip_previous_rounded),
                color: Colors.white70,
              ),
              if (MediaQuery.sizeOf(context).width >= 600)
                IconButton(
                  onPressed: () => setState(() => _shuffle = !_shuffle),
                  icon: const Icon(Icons.shuffle_rounded),
                  color: _shuffle ? const Color(0xffef4bff) : Colors.white38,
                ),
              const Spacer(),
              Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xffef4bff),
                ),
                child: IconButton(
                  onPressed: _togglePlay,
                  icon: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                  iconSize: 28,
                  color: Colors.white,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Skip forward 15 seconds',
                onPressed: () => _skipBy(const Duration(seconds: 15)),
                icon: const Icon(Icons.fast_forward_rounded),
                color: Colors.white70,
              ),
              IconButton(
                onPressed: _next,
                icon: const Icon(Icons.skip_next_rounded),
                color: Colors.white70,
              ),
              if (MediaQuery.sizeOf(context).width >= 600) ...[
                IconButton(
                  onPressed: () => setState(() {
                    if (!_repeat && !_repeatOne) {
                      _repeat = true;
                    } else if (_repeat) {
                      _repeat = false;
                      _repeatOne = true;
                    } else {
                      _repeatOne = false;
                    }
                  }),
                  icon: Icon(
                    _repeatOne
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                  ),
                  color: (_repeat || _repeatOne)
                      ? const Color(0xffef4bff)
                      : Colors.white38,
                ),
                const SizedBox(width: 14),
                const Icon(
                  Icons.volume_up_rounded,
                  color: Colors.white38,
                  size: 18,
                ),
                SizedBox(
                  width: 110,
                  child: Slider(
                    value: _volume,
                    onChanged: _midiActive
                        ? null
                        : (value) {
                            setState(() => _volume = value);
                            if (_casting) {
                              _runAsyncSafely(
                                _dlnaCast.setVolume(_volumeFor(_current)),
                                'Setting cast volume',
                              );
                            } else if (_dspActive) {
                              _runAsyncSafely(
                                _dspPlayer.setVolume(_volumeFor(_current)),
                                'Setting DSP volume',
                              );
                            } else {
                              _runAsyncSafely(
                                _player.setVolume(_volumeFor(_current)),
                                'Setting volume',
                              );
                            }
                          },
                    activeColor: Colors.white70,
                    inactiveColor: Colors.white12,
                  ),
                ),
              ],
            ],
          ],
        ),
      ],
    ),
  );
}

class SpectrumPainter extends CustomPainter {
  const SpectrumPainter({required this.fft, required this.active});
  final Float32List? fft;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final bins = fft;
    if (!active || bins == null || bins.isEmpty) return;
    final paint = Paint()..strokeCap = StrokeCap.round;
    const count = 52;
    for (var i = 0; i < count; i++) {
      final x = (i + .5) * size.width / count;
      final bin = ((i / count) * bins.length).floor().clamp(0, bins.length - 1);
      final normalized = (bins[bin] * 3.5).clamp(.025, .82);
      final height = size.height * normalized.clamp(.08, .82);
      paint.color = Color.lerp(
        const Color(0xff5b4aff),
        const Color(0xffff4ccf),
        i / count,
      )!.withOpacity(.55 + normalized * .4);
      paint.strokeWidth = math.max(2, size.width / count - 5);
      canvas.drawLine(
        Offset(x, size.height / 2 - height / 2),
        Offset(x, size.height / 2 + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) =>
      oldDelegate.fft != fft || oldDelegate.active != active;
}
