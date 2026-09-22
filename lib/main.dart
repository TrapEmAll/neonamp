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

import 'dsp_local_player.dart';

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

bool isSupportedLibraryAudioPath(String path) {
  const extensions = {
    '.mp3',
    '.flac',
    '.wav',
    '.ogg',
    '.m4a',
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
  };
  final lowerPath = path.toLowerCase();
  final dot = lowerPath.lastIndexOf('.');
  return dot >= 0 && extensions.contains(lowerPath.substring(dot));
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
  final suffix = '.neonamp-${DateTime.now().microsecondsSinceEpoch}';
  final temporary = File('${file.path}$suffix.tmp');
  final backup = File('${file.path}$suffix.bak');
  var movedOriginal = false;
  try {
    await temporary.writeAsBytes(output, flush: true);
    await file.rename(backup.path);
    movedOriginal = true;
    await temporary.rename(file.path);
    await backup.delete();
  } catch (_) {
    if (movedOriginal && !await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
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
  final suffix = '.neonamp-${DateTime.now().microsecondsSinceEpoch}';
  final temporary = File('${file.path}$suffix.tmp');
  final backup = File('${file.path}$suffix.bak');
  var movedOriginal = false;
  try {
    await temporary.writeAsBytes(output, flush: true);
    await file.rename(backup.path);
    movedOriginal = true;
    await temporary.rename(file.path);
    await backup.delete();
  } catch (_) {
    if (movedOriginal && !await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
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
  final suffix = '.neonamp-${DateTime.now().microsecondsSinceEpoch}';
  final temporary = File('${file.path}$suffix.tmp');
  final backup = File('${file.path}$suffix.bak');
  var movedOriginal = false;
  try {
    await temporary.writeAsBytes(output, flush: true);
    await file.rename(backup.path);
    movedOriginal = true;
    await temporary.rename(file.path);
    await backup.delete();
  } catch (_) {
    if (movedOriginal && !await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
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
  } catch (_) {
    if (movedOriginal && !await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
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

Future<void> writeTrackMetadata(File file, List<String> values) async {
  if (isAacAudioPath(file.path)) {
    await writeAacTags(file, values);
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
    lyrics: lyrics ?? this.lyrics,
    rating: rating ?? this.rating,
    playCount: playCount ?? this.playCount,
    favorite: favorite ?? this.favorite,
    artwork: artwork ?? this.artwork,
    replayGainDb: replayGainDb ?? this.replayGainDb,
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

  void _bindPlayerStreams() {
    _positionSubscription = player.onPositionChanged.listen(
      (position) => _broadcast(position: position),
    );
    _durationSubscription = player.onDurationChanged.listen((duration) {
      final current = mediaItem.value;
      if (current != null) mediaItem.add(current.copyWith(duration: duration));
      _broadcast();
    });
    _stateSubscription = player.onPlayerStateChanged.listen(
      (state) => _broadcast(state: state),
    );
  }

  Future<void> switchPlayer(AudioPlayer nextPlayer) async {
    await _positionSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _stateSubscription?.cancel();
    player = nextPlayer;
    _bindPlayerStreams();
    _broadcast();
  }

  Future<void> playTrack(Track track) async {
    final duration = mediaItem.value?.duration;
    mediaItem.add(
      MediaItem(
        id: track.path,
        title: track.name,
        artist: track.artist,
        album: track.album,
        artUri: null,
        duration: duration,
      ),
    );
    await player.stop();
    await player.play(
      track.path.startsWith('http')
          ? UrlSource(track.path)
          : DeviceFileSource(track.path),
    );
    await player.setPlaybackRate(_playbackSpeed);
  }

  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    await player.setPlaybackRate(speed);
    _broadcast();
  }

  void publishTrack(Track track) {
    mediaItem.add(
      MediaItem(
        id: track.path,
        title: track.name,
        artist: track.artist,
        album: track.album,
        artUri: null,
      ),
    );
  }

  void syncExternalState({
    Duration? position,
    Duration? duration,
    required PlayerState state,
  }) {
    final current = mediaItem.value;
    if (current != null && duration != null) {
      mediaItem.add(current.copyWith(duration: duration));
    }
    _broadcast(position: position, state: state);
  }

  @override
  Future<void> play() => onPlayRequested?.call() ?? player.resume();

  @override
  Future<void> pause() => onPauseRequested?.call() ?? player.pause();

  @override
  Future<void> stop() => onStopRequested?.call() ?? player.stop();

  @override
  Future<void> seek(Duration position) =>
      onSeekRequested?.call(position) ?? player.seek(position);

  @override
  Future<void> skipToNext() async {
    await onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await onPrevious?.call();
  }

  void _broadcast({Duration? position, PlayerState? state}) {
    final currentState = state ?? player.state;
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
        updatePosition: position ?? Duration.zero,
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

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
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
    if (!mounted) return;
    setState(() => _themeName = prefs.getString('themeName') ?? 'Neon');
  }

  Future<void> _setTheme(String themeName) async {
    setState(() => _themeName = themeName);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeName', themeName);
  }

  Future<void> _addCustomSkin(ThemeSkin skin) async {
    if (builtInSkins().any((builtin) => builtin.name == skin.name)) {
      throw const FormatException('Built-in skin names cannot be replaced.');
    }
    setState(() {
      _customSkins[skin.name] = skin;
      _themeName = skin.name;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'customSkins',
      jsonEncode(_customSkins.values.map((value) => value.toJson()).toList()),
    );
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
  DspLocalPlayer _dspPlayer = DspLocalPlayer();
  NeonAudioHandler? _audioHandler;
  final List<Track> _queue = [];
  final List<Track> _library = [];
  final List<String> _playHistory = [];
  final Map<String, int> _resumePositions = {};
  final List<String> _libraryFolders = [];
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
  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 4, seconds: 12);
  PlayerState _playerState = PlayerState.stopped;
  int _selected = 0;
  double _volume = .82;
  bool _shuffle = false;
  bool _repeat = false;
  bool _repeatOne = false;
  bool _crossfade = false;
  int _crossfadeSeconds = 3;
  bool _equalizerEnabled = false;
  String _activeView = 'queue';
  String _searchQuery = '';
  String _libraryFilter = 'All';
  String _librarySort = 'Added';
  bool _librarySortDescending = false;
  final Set<String> _selectedLibraryPaths = <String>{};
  final List<double> _eqBands = List<double>.filled(10, 0);
  String _eqPreset = 'Flat';
  bool _crossfadeInProgress = false;
  bool _dspActive = false;
  double _playbackSpeed = 1.0;
  bool _replayGainEnabled = false;
  Timer? _sleepTimer;
  Timer? _resumeSaveTimer;
  DateTime? _sleepDeadline;

  AudioPlayer get _player => _activePlayer;

  Track? get _current =>
      _queue.isEmpty ? null : _queue[_selected.clamp(0, _queue.length - 1)];
  bool get _isPlaying => _playerState == PlayerState.playing;

  double _volumeFor(Track? track) => playbackVolume(
    volume: _volume,
    replayGainDb: track?.replayGainDb,
    replayGainEnabled: _replayGainEnabled,
  );

  @override
  void initState() {
    super.initState();
    _bindPlayerStreams();
    _bindDspStreams();
    _initializeWindowsMediaKeys();
    _initializeAudioService();
    _loadQueue();
  }

  Future<void> _initializeWindowsMediaKeys() async {
    if (!Platform.isWindows) return;
    const channel = MethodChannel('neonamp/system_controls');
    channel.setMethodCallHandler((call) async {
      if (call.method != 'mediaKey') return null;
      switch (call.arguments as String?) {
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
          await _player.stop();
          break;
      }
      return null;
    });
  }

  Future<void> _syncWindowsMediaSession() async {
    if (!Platform.isWindows) return;
    final track = _current;
    if (track == null) return;
    const channel = MethodChannel('neonamp/system_controls');
    await channel.invokeMethod<void>('setMediaSession', {
      'title': track.name,
      'artist': track.artist,
      'album': track.album,
      'isPlaying': _isPlaying,
      'durationMs': _duration.inMilliseconds,
    });
  }

  void _bindPlayerStreams() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _dspPositionSub?.cancel();
    _dspDurationSub?.cancel();
    _dspStateSub?.cancel();
    _dspCompleteSub?.cancel();
    _positionSub = _player.onPositionChanged.listen((value) {
      if (!mounted) return;
      setState(() => _position = value);
      _rememberResumePosition(value);
      if (_crossfade && !_crossfadeInProgress && _isPlaying) {
        final remaining = _duration - value;
        if (remaining <= Duration(seconds: _crossfadeSeconds) &&
            remaining > Duration.zero) {
          unawaited(_crossfadeToNext());
        }
      }
    });
    _durationSub = _player.onDurationChanged.listen(
      (value) => setState(() => _duration = value),
    );
    _stateSub = _player.onPlayerStateChanged.listen((value) {
      setState(() => _playerState = value);
      unawaited(_syncWindowsMediaSession());
    });
    _completeSub = _player.onPlayerComplete.listen((_) => _handleComplete());
  }

  void _bindDspStreams() {
    _dspPositionSub?.cancel();
    _dspDurationSub?.cancel();
    _dspStateSub?.cancel();
    _dspCompleteSub?.cancel();
    _dspPositionSub = _dspPlayer.onPositionChanged.listen((value) {
      if (!mounted || !_dspActive) return;
      setState(() => _position = value);
      _rememberResumePosition(value);
      if (_crossfade && !_crossfadeInProgress && _isPlaying) {
        final remaining = _duration - value;
        if (remaining <= Duration(seconds: _crossfadeSeconds) &&
            remaining > Duration.zero) {
          unawaited(_crossfadeToNext());
        }
      }
      _audioHandler?.syncExternalState(
        position: value,
        state: PlayerState.playing,
      );
    });
    _dspDurationSub = _dspPlayer.onDurationChanged.listen((value) {
      if (!mounted || !_dspActive) return;
      setState(() => _duration = value);
      _audioHandler?.syncExternalState(duration: value, state: _playerState);
    });
    _dspStateSub = _dspPlayer.onPlayerStateChanged.listen((value) {
      if (!mounted || !_dspActive) return;
      setState(() => _playerState = value);
      _audioHandler?.syncExternalState(position: _position, state: value);
      unawaited(_syncWindowsMediaSession());
    });
    _dspCompleteSub = _dspPlayer.onPlayerComplete.listen((_) {
      if (_dspActive) unawaited(_handleComplete());
    });
  }

  Future<void> _initializeAudioService() async {
    if (!Platform.isAndroid) return;
    _audioHandler = await AudioService.init(
      builder: () => NeonAudioHandler(_player),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.neonamp.audio',
        androidNotificationChannelName: 'NeonAmp playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: false,
      ),
    );
    _audioHandler!.onNext = _next;
    _audioHandler!.onPrevious = _previous;
    _audioHandler!.onPlayRequested = _playCurrent;
    _audioHandler!.onPauseRequested = _pauseCurrent;
    _audioHandler!.onStopRequested = _stopCurrent;
    _audioHandler!.onSeekRequested = _seekCurrent;
  }

  Future<void> _playCurrent() async {
    if (_dspActive) {
      await _dspPlayer.resume();
    } else {
      await _player.resume();
    }
  }

  Future<void> _pauseCurrent() async {
    if (_dspActive) {
      await _dspPlayer.pause();
    } else {
      await _player.pause();
    }
  }

  Future<void> _stopCurrent() async {
    if (_dspActive) {
      await _dspPlayer.stop();
    } else {
      await _player.stop();
    }
  }

  Future<void> _seekCurrent(Duration position) async {
    if (_dspActive) {
      await _dspPlayer.seek(position);
    } else {
      await _player.seek(position);
    }
  }

  Future<void> _setPlaybackSpeed(double speed) async {
    final value = speed.clamp(0.5, 2.0).toDouble();
    setState(() => _playbackSpeed = value);
    if (_current != null) {
      if (_dspActive) {
        await _dspPlayer.setPlaybackSpeed(value);
      } else {
        await _player.setPlaybackRate(value);
      }
      await _audioHandler?.setPlaybackSpeed(value);
    }
    await _saveQueue();
  }

  Future<void> _setEqualizerEnabled(bool enabled) async {
    final wasPlaying = _isPlaying;
    final previousPosition = _position;
    setState(() => _equalizerEnabled = enabled);
    if (_current != null && (wasPlaying || _dspActive)) {
      await _select(_selected);
      if (previousPosition > Duration.zero) {
        await _seekCurrent(previousPosition);
      }
      if (!wasPlaying) await _pauseCurrent();
    }
    await _saveQueue();
    unawaited(_syncWindowsMediaSession());
  }

  Future<void> _setReplayGainEnabled(bool enabled) async {
    final wasPlaying = _isPlaying;
    final previousPosition = _position;
    setState(() => _replayGainEnabled = enabled);
    if (_current != null && (wasPlaying || _dspActive)) {
      await _select(_selected);
      if (previousPosition > Duration.zero) {
        await _seekCurrent(previousPosition);
      }
      if (!wasPlaying) await _pauseCurrent();
    }
    await _saveQueue();
  }

  Future<void> _handleComplete() async {
    if (_crossfadeInProgress) return;
    final path = _current?.path;
    if (path != null) {
      _resumePositions.remove(path);
      unawaited(_saveQueue());
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

  void _armSleepTimer() {
    _sleepTimer?.cancel();
    final deadline = _sleepDeadline;
    if (deadline == null) return;
    final remaining = sleepTimerRemaining(deadline, DateTime.now())!;
    if (remaining == Duration.zero) {
      unawaited(_stopCurrent());
      return;
    }
    _sleepTimer = Timer(remaining, () {
      _sleepDeadline = null;
      unawaited(_stopCurrent());
      unawaited(_saveQueue());
    });
  }

  Future<void> _setSleepTimer(Duration? duration) async {
    _sleepTimer?.cancel();
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
    final savedLibrary = prefs.getStringList('library') ?? [];
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
      _queue.addAll(
        saved.map(
          (path) => Track(path: path, name: path.split(RegExp(r'[/\\]')).last),
        ),
      );
      _library.addAll(
        savedLibrary.map(
          (value) => Track.fromJson(jsonDecode(value) as Map<String, dynamic>),
        ),
      );
      _playHistory.addAll(savedPlayHistory);
      if (savedResumePositions != null) {
        final decoded =
            jsonDecode(savedResumePositions) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final position = (entry.value as num?)?.toInt();
          if (position != null && position > 0) {
            _resumePositions[entry.key] = position;
          }
        }
      }
      _libraryFolders.addAll(savedFolders);
      _podcastFeeds.addAll(savedPodcastFeeds);
      if (savedPlaylists != null) {
        final decoded = jsonDecode(savedPlaylists) as Map<String, dynamic>;
        for (final entry in decoded.entries)
          _playlists[entry.key] = (entry.value as List).cast<String>();
      }
      if (savedSmartPlaylists != null) {
        final decoded = jsonDecode(savedSmartPlaylists) as List;
        _smartPlaylists.addAll(
          decoded.map(
            (entry) => SmartPlaylist.fromJson(entry as Map<String, dynamic>),
          ),
        );
      }
      if (savedPlugins != null) {
        final decoded = jsonDecode(savedPlugins) as List;
        for (final entry in decoded) {
          try {
            final plugin = NeonAmpPlugin.fromJson(
              entry as Map<String, dynamic>,
            );
            _plugins[plugin.id] = plugin;
          } on Object catch (error) {
            debugPrint('Skipping invalid saved plugin: $error');
          }
        }
      }
      if (savedSettings != null) {
        final settings = jsonDecode(savedSettings) as Map<String, dynamic>;
        _volume = (settings['volume'] as num?)?.toDouble() ?? _volume;
        _crossfade = settings['crossfade'] as bool? ?? false;
        _crossfadeSeconds =
            (settings['crossfadeSeconds'] as num?)?.toInt() ?? 3;
        _equalizerEnabled = settings['equalizerEnabled'] as bool? ?? false;
        _eqPreset = settings['eqPreset'] as String? ?? 'Flat';
        _playbackSpeed = (settings['playbackSpeed'] as num?)?.toDouble() ?? 1.0;
        _replayGainEnabled = settings['replayGainEnabled'] as bool? ?? false;
        final sleepTimerEnd = (settings['sleepTimerEndMs'] as num?)?.toInt();
        _sleepDeadline = sleepTimerEnd == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(sleepTimerEnd);
        _librarySort = settings['librarySort'] as String? ?? 'Added';
        _librarySortDescending =
            settings['librarySortDescending'] as bool? ?? false;
        final savedBands = (settings['eqBands'] as List?)?.cast<num>();
        if (savedBands != null && savedBands.length == _eqBands.length) {
          for (var i = 0; i < _eqBands.length; i++) {
            _eqBands[i] = savedBands[i].toDouble();
          }
        }
      }
    });
    _armSleepTimer();
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'queue',
      _queue.map((track) => track.path).toList(),
    );
    await prefs.setStringList(
      'library',
      _library.map((track) => jsonEncode(track.toJson())).toList(),
    );
    await prefs.setStringList('playHistory', _playHistory);
    await prefs.setString('resumePositions', jsonEncode(_resumePositions));
    await prefs.setStringList('libraryFolders', _libraryFolders);
    await prefs.setStringList('podcastFeeds', _podcastFeeds);
    await prefs.setString('playlists', jsonEncode(_playlists));
    await prefs.setString(
      'smartPlaylists',
      jsonEncode(_smartPlaylists.map((playlist) => playlist.toJson()).toList()),
    );
    await prefs.setString(
      'plugins',
      jsonEncode(_plugins.values.map((plugin) => plugin.toJson()).toList()),
    );
    await prefs.setString(
      'settings',
      jsonEncode({
        'volume': _volume,
        'crossfade': _crossfade,
        'crossfadeSeconds': _crossfadeSeconds,
        'equalizerEnabled': _equalizerEnabled,
        'eqPreset': _eqPreset,
        'eqBands': _eqBands,
        'playbackSpeed': _playbackSpeed,
        'replayGainEnabled': _replayGainEnabled,
        'sleepTimerEndMs': _sleepDeadline?.millisecondsSinceEpoch,
        'librarySort': _librarySort,
        'librarySortDescending': _librarySortDescending,
      }),
    );
  }

  Future<void> _addFiles() async {
    final result = await FilePicker.pickFiles(type: FileType.audio);
    if (result.isEmpty) return;
    for (final file in result) {
      final path = file.path;
      if (path == null || _queue.any((track) => track.path == path)) continue;
      final track = await _readTrack(path, file.name);
      if (!mounted) return;
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == path)) _library.add(track);
      });
    }
    await _saveQueue();
    if (_queue.length == result.length && _queue.isNotEmpty) await _select(0);
  }

  Future<void> _addFolder() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a music folder',
    );
    if (directory == null) return;
    if (!_libraryFolders.contains(directory)) _libraryFolders.add(directory);
    await _scanFolder(directory);
    await _saveQueue();
  }

  Future<void> _scanFolder(String directory) async {
    final files = Directory(directory)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => isSupportedLibraryAudioPath(file.path))
        .toList();
    for (final file in files) {
      if (_queue.any((track) => track.path == file.path)) continue;
      final track = await _readTrack(file.path, file.uri.pathSegments.last);
      if (!mounted) return;
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == file.path))
          _library.add(track);
      });
    }
  }

  Future<void> _rescanFolders() async {
    if (_libraryFolders.isEmpty) {
      await _addFolder();
      return;
    }
    for (final folder in List<String>.from(_libraryFolders)) {
      if (Directory(folder).existsSync()) await _scanFolder(folder);
    }
    await _saveQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Rescanned ${_libraryFolders.length} folder(s)'),
        ),
      );
    }
  }

  Future<void> _importPlaylist() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8', 'pls'],
    );
    if (result.isEmpty || result.first.path == null) return;
    final playlistPath = result.first.path!;
    final lines = await File(playlistPath).readAsLines();
    final entries = <({String path, String? title})>[];
    final extension = playlistPath.split('.').last.toLowerCase();
    if (extension == 'pls') {
      final paths = <int, String>{};
      final titles = <int, String>{};
      for (final line in lines) {
        final pathMatch = RegExp(
          r'^\s*File(\d+)\s*=\s*(.+)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (pathMatch != null) {
          paths[int.parse(pathMatch.group(1)!)] = pathMatch.group(2)!.trim();
          continue;
        }
        final titleMatch = RegExp(
          r'^\s*Title(\d+)\s*=\s*(.*)$',
          caseSensitive: false,
        ).firstMatch(line);
        if (titleMatch != null) {
          titles[int.parse(titleMatch.group(1)!)] = titleMatch.group(2)!.trim();
        }
      }
      for (final index in paths.keys.toList()..sort()) {
        entries.add((path: paths[index]!, title: titles[index]));
      }
    } else {
      String? pendingTitle;
      for (final raw in lines) {
        final line = raw.trim();
        if (line.toUpperCase().startsWith('#EXTINF:')) {
          final comma = line.indexOf(',');
          pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : null;
          continue;
        }
        if (line.isEmpty || line.startsWith('#')) continue;
        entries.add((path: line, title: pendingTitle));
        pendingTitle = null;
      }
    }
    for (final entry in entries) {
      final path = entry.path;
      if (path.isEmpty ||
          path.startsWith('#') ||
          _queue.any((track) => track.path == path))
        continue;
      final name = path.startsWith('http')
          ? (Uri.tryParse(path)?.host ?? 'Internet stream')
          : path.split(RegExp(r'[/\\]')).last;
      final track = Track(
        path: path,
        name: entry.title?.isNotEmpty == true
            ? entry.title!
            : name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        artist: path.startsWith('http') ? 'Online radio' : 'Local library',
      );
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == path)) _library.add(track);
      });
    }
    await _saveQueue();
  }

  Future<Track> _readTrack(String path, String fileName) async {
    final fallback = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    try {
      final metadata = readMetadata(File(path), getImage: true);
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

  Future<void> _select(int index) async {
    if (index < 0 || index >= _queue.length) return;
    setState(() {
      _selected = index;
      _position = Duration.zero;
      final track = _queue[index];
      _playHistory
        ..clear()
        ..addAll(addToPlayHistory(_playHistory, track.path));
      final libraryIndex = _library.indexWhere(
        (item) => item.path == track.path,
      );
      if (libraryIndex >= 0)
        _library[libraryIndex] = track.copyWith(playCount: track.playCount + 1);
    });
    final track = _queue[index];
    final resumePosition = restoreResumePosition(_resumePositions[track.path]);
    final trackVolume = _volumeFor(track);
    final shouldUseDsp = _equalizerEnabled && !track.path.startsWith('http');
    if (shouldUseDsp) {
      if (!_dspActive) {
        await _player.stop();
        _dspActive = true;
      }
      await _dspPlayer.play(
        track.path,
        volume: trackVolume,
        playbackSpeed: _playbackSpeed,
        equalizerEnabled: true,
        bands: _eqBands,
      );
      _audioHandler?.publishTrack(track);
    } else {
      if (_dspActive) {
        await _dspPlayer.stop();
        _dspActive = false;
      }
      await _player.setVolume(trackVolume);
      if (_audioHandler != null) {
        await _audioHandler!.playTrack(track);
      } else {
        await _player.stop();
        await _player.play(
          track.path.startsWith('http')
              ? UrlSource(track.path)
              : DeviceFileSource(track.path),
        );
        await _player.setPlaybackRate(_playbackSpeed);
      }
    }
    if (resumePosition != null) await _seekCurrent(resumePosition);
    await _saveQueue();
  }

  void _rememberResumePosition(Duration position) {
    final path = _current?.path;
    if (path == null || position <= Duration.zero) return;
    _resumePositions[path] = position.inMilliseconds;
    _resumeSaveTimer?.cancel();
    _resumeSaveTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_saveQueue());
    });
  }

  Future<void> _togglePlay() async {
    if (_current == null) {
      await _addFiles();
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

  Future<void> _next() async {
    if (_queue.isEmpty || _crossfadeInProgress) return;
    if (_crossfade && _isPlaying && !_crossfadeInProgress) {
      await _crossfadeToNext();
      return;
    }
    final next = _shuffle
        ? math.Random().nextInt(_queue.length)
        : (_selected + 1) % _queue.length;
    await _select(next);
  }

  Future<void> _crossfadeToNext() async {
    if (_queue.isEmpty || _crossfadeInProgress) return;
    if (_dspActive) {
      await _crossfadeDspToNext();
      return;
    }
    _crossfadeInProgress = true;
    final previousPlayer = _player;
    final next = _shuffle
        ? math.Random().nextInt(_queue.length)
        : (_selected + 1) % _queue.length;
    final previousTrack = _queue[_selected];
    final track = _queue[next];
    final incomingPlayer = AudioPlayer();
    try {
      setState(() {
        _selected = next;
        _position = Duration.zero;
        _playHistory
          ..clear()
          ..addAll(addToPlayHistory(_playHistory, track.path));
        final libraryIndex = _library.indexWhere(
          (item) => item.path == track.path,
        );
        if (libraryIndex >= 0) {
          _library[libraryIndex] = track.copyWith(
            playCount: track.playCount + 1,
          );
        }
      });
      await incomingPlayer.setVolume(0);
      await incomingPlayer.play(
        track.path.startsWith('http')
            ? UrlSource(track.path)
            : DeviceFileSource(track.path),
      );
      final steps = math.max(1, _crossfadeSeconds * 10);
      for (var step = 1; step <= steps; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final progress = step / steps;
        await previousPlayer.setVolume(
          _volumeFor(previousTrack) * (1 - progress),
        );
        await incomingPlayer.setVolume(_volumeFor(track) * progress);
      }
      await previousPlayer.stop();
      await previousPlayer.dispose();
      _activePlayer = incomingPlayer;
      _bindPlayerStreams();
      await _audioHandler?.switchPlayer(incomingPlayer);
      await _saveQueue();
    } catch (_) {
      await incomingPlayer.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Crossfade could not start the next track.'),
          ),
        );
      }
    } finally {
      _crossfadeInProgress = false;
    }
  }

  Future<void> _crossfadeDspToNext() async {
    if (_queue.isEmpty || _crossfadeInProgress) return;
    _crossfadeInProgress = true;
    final previousPlayer = _dspPlayer;
    final next = _shuffle
        ? math.Random().nextInt(_queue.length)
        : (_selected + 1) % _queue.length;
    final previousTrack = _queue[_selected];
    final track = _queue[next];
    final incomingPlayer = DspLocalPlayer();
    try {
      setState(() {
        _selected = next;
        _position = Duration.zero;
        _playHistory
          ..clear()
          ..addAll(addToPlayHistory(_playHistory, track.path));
        final libraryIndex = _library.indexWhere(
          (item) => item.path == track.path,
        );
        if (libraryIndex >= 0) {
          _library[libraryIndex] = track.copyWith(
            playCount: track.playCount + 1,
          );
        }
      });
      await incomingPlayer.play(
        track.path,
        volume: 0,
        playbackSpeed: _playbackSpeed,
        equalizerEnabled: true,
        bands: _eqBands,
      );
      final steps = math.max(1, _crossfadeSeconds * 10);
      for (var step = 1; step <= steps; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final progress = step / steps;
        await previousPlayer.setVolume(
          _volumeFor(previousTrack) * (1 - progress),
        );
        await incomingPlayer.setVolume(_volumeFor(track) * progress);
      }
      await previousPlayer.stop();
      await previousPlayer.dispose();
      _dspPlayer = incomingPlayer;
      _bindDspStreams();
      _audioHandler?.publishTrack(track);
      await _saveQueue();
    } catch (_) {
      await incomingPlayer.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Crossfade could not start the next track.'),
          ),
        );
      }
    } finally {
      _crossfadeInProgress = false;
    }
  }

  Future<void> _previous() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) return _seekCurrent(Duration.zero);
    await _select((_selected - 1 + _queue.length) % _queue.length);
  }

  Future<void> _remove(int index) async {
    setState(() {
      _queue.removeAt(index);
      if (_queue.isEmpty) _selected = 0;
      if (_selected >= _queue.length) _selected = _queue.length - 1;
    });
    await _saveQueue();
  }

  Future<void> _reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex || oldIndex < 0 || newIndex < 0) return;
    final selectedPath = _current?.path;
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final track = _queue.removeAt(oldIndex);
      _queue.insert(newIndex.clamp(0, _queue.length), track);
      final selectedIndex = selectedPath == null
          ? -1
          : _queue.indexWhere((item) => item.path == selectedPath);
      if (selectedIndex >= 0) _selected = selectedIndex;
    });
    await _saveQueue();
  }

  Future<void> _clearQueue() async {
    await _player.stop();
    if (_dspActive) await _dspPlayer.stop();
    setState(() {
      _queue.clear();
      _selected = 0;
      _position = Duration.zero;
      _duration = Duration.zero;
      _playerState = PlayerState.stopped;
    });
    await _saveQueue();
  }

  Future<void> _addStream() async {
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
    if (url == null || url.isEmpty) return;
    setState(
      () => _queue.add(
        Track(
          path: url,
          name: Uri.tryParse(url)?.host ?? 'Internet stream',
          artist: 'Online radio',
        ),
      ),
    );
    await _saveQueue();
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
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'NeonAmp/0.1');
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      client.close(force: true);
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
    if (path == null) return;
    final name = (station['name'] as String? ?? 'Internet radio').trim();
    final existingIndex = _library.indexWhere((track) => track.path == path);
    setState(() {
      if (existingIndex >= 0) {
        final track = _library[existingIndex];
        _library[existingIndex] = track.copyWith(favorite: !track.favorite);
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
    if (url == null || url.isEmpty) return;
    try {
      final added = await _loadPodcastFeed(url);
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
    }
    await _saveQueue();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Refreshed podcasts ($added new episode(s))')),
      );
    }
  }

  Future<int> _loadPodcastFeed(String feedUrl) async {
    final request = await HttpClient().getUrl(Uri.parse(feedUrl));
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Podcast feed returned ${response.statusCode}');
    }
    final xml = await response.transform(utf8.decoder).join();
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
      if (enclosure == null || enclosure.isEmpty) continue;
      final title = _rssValue(item, 'title') ?? 'Podcast episode';
      final author =
          _rssValue(item, 'author') ?? _rssValue(item, 'creator') ?? 'Podcast';
      if (_queue.any((track) => track.path == enclosure)) continue;
      episodes.add(
        Track(
          path: enclosure,
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
    if (!track.path.startsWith('http')) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a podcast download folder',
    );
    if (directory == null) return;
    try {
      final request = await HttpClient().getUrl(Uri.parse(track.path));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Episode returned ${response.statusCode}');
      }
      final safeName = track.name
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final extension = Uri.tryParse(track.path)?.path.split('.').last;
      final filename =
          '$safeName.${extension != null && extension.length <= 5 ? extension : 'mp3'}';
      final target = File(
        '${Directory(directory).path}${Platform.pathSeparator}$filename',
      );
      await response.pipe(target.openWrite());
      final downloaded = track.copyWith(path: target.path);
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

  Future<void> _syncToDeviceFolder() async {
    final destination = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a device music folder',
    );
    if (destination == null) return;
    final selected = _selectedLibraryPaths.isEmpty
        ? _library
        : _library.where((track) => _selectedLibraryPaths.contains(track.path));
    final tracks = <Track>[];
    final seen = <String>{};
    for (final track in selected) {
      if (track.path.startsWith('http')) continue;
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
      final target = File('$destination${Platform.pathSeparator}$name');
      if (source.absolute.path.toLowerCase() ==
          target.absolute.path.toLowerCase()) {
        manifest.add(name);
        copied++;
        continue;
      }
      try {
        await source.copy(target.path);
        manifest
          ..add('#EXTINF:-1,${track.name}')
          ..add(name);
        copied++;
      } on Object {
        skipped++;
      }
    }
    try {
      await File('$destination${Platform.pathSeparator}neonamp-sync.m3u8')
          .writeAsString('${manifest.join('\n')}\n');
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
    if (track.path.startsWith('http')) return;
    final destination = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a conversion folder',
    );
    if (destination == null) return;
    final usedNames = <String>{};
    final requested = convertedM4aFileName(track.path);
    final outputName = nextSyncFileName(requested, usedNames);
    final output = '$destination${Platform.pathSeparator}$outputName';
    try {
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
      if (selection == null) return;
      final destination = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a CD rip folder',
      );
      if (destination == null) return;
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
      await _select(_selected);
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
    setState(() => _library[index] = track.copyWith(favorite: !track.favorite));
    _saveQueue();
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
    try {
      await writeTrackMetadata(File(track.path), values);
      final written = readMetadata(File(track.path));
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
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This file format does not support tag writing yet.'),
          ),
        );
    }
    final updated = track.copyWith(
      name: values[0],
      artist: values[1],
      album: values[2],
      genre: values[3],
      rating: int.tryParse(values[4]) ?? track.rating,
      year: int.tryParse(values[5]) ?? track.year,
      trackNumber: int.tryParse(values[6]) ?? track.trackNumber,
      trackTotal: int.tryParse(values[7]) ?? track.trackTotal,
      discNumber: int.tryParse(values[8]) ?? track.discNumber,
      discTotal: int.tryParse(values[9]) ?? track.discTotal,
      lyrics: values[10].trim().isEmpty ? track.lyrics : values[10],
    );
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
    if (values == null) return;

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
    if (track.path.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cover art can only be embedded in local files.'),
        ),
      );
      return;
    }
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result.isEmpty || result.first.path == null) return;
    final imageFile = File(result.first.path!);
    final bytes = await imageFile.readAsBytes();
    if (bytes.isEmpty) return;
    final extension = imageFile.path.split('.').last.toLowerCase();
    final mimeType = switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    try {
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
    if (name == null || name.isEmpty) return;
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
    if (name == null || name.isEmpty || name == oldName) return;
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
    if (confirmed != true) return;
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
    if (result == null) return;
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
                                    setState(
                                      () => _plugins[plugin.id] = plugin
                                          .copyWith(enabled: value),
                                    );
                                    unawaited(_saveQueue());
                                    setDialogState(() {});
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Remove plugin',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () {
                                    setState(() => _plugins.remove(plugin.id));
                                    unawaited(_saveQueue());
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
    if (selected != null) widget.onThemeChanged?.call(selected);
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
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Spectrum visualizer'),
        content: SizedBox(
          width: 560,
          height: 220,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => CustomPaint(
              painter: SpectrumPainter(
                progress: _pulse.value,
                active: _isPlaying,
              ),
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
                  setState(() => _crossfade = value);
                  unawaited(_saveQueue());
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
                          setState(() => _crossfadeSeconds = value.round());
                          unawaited(_saveQueue());
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
                  unawaited(_setReplayGainEnabled(value));
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
    final tracks = _tracksForSmartPlaylist(playlist);
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No tracks match ${playlist.name}.')),
      );
      return;
    }
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
    if (name == null) return;
    setState(() {
      final tracks = _playlists[name]!;
      if (!tracks.contains(track.path)) tracks.add(track.path);
    });
    await _saveQueue();
  }

  Future<void> _showEqualizer() async {
    const builtInPresets = [
      'Flat',
      'Rock',
      'Pop',
      'Jazz',
      'Classical',
      'Bass boost',
    ];
    final pluginPresets = <String, List<double>>{};
    for (final plugin in _plugins.values.where((plugin) => plugin.enabled)) {
      pluginPresets.addAll(plugin.equalizerPresets);
    }
    final presets = [...builtInPresets, ...pluginPresets.keys];
    final selectedPreset = presets.contains(_eqPreset) ? _eqPreset : 'Flat';
    if (_eqPreset != selectedPreset) _eqPreset = selectedPreset;
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
                onChanged: (value) {
                  unawaited(_setEqualizerEnabled(value));
                  setDialogState(() {});
                },
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedPreset,
                  decoration: const InputDecoration(labelText: 'Preset'),
                  items: presets
                      .map(
                        (preset) => DropdownMenuItem(
                          value: preset,
                          child: Text(preset),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _eqPreset = value;
                      final pluginBands = pluginPresets[value];
                      for (var i = 0; i < _eqBands.length; i++) {
                        _eqBands[i] =
                            pluginBands?[i] ??
                            (value == 'Bass boost' && i < 3 ? 6 : 0);
                      }
                    });
                    if (_dspActive) {
                      _dspPlayer.applyEqualizer(
                        enabled: _equalizerEnabled,
                        bands: _eqBands,
                      );
                    }
                    setDialogState(() {});
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Crossfade between tracks'),
                  subtitle: Text('Overlap for $_crossfadeSeconds seconds'),
                  value: _crossfade,
                  onChanged: (value) {
                    setState(() => _crossfade = value);
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
                    unawaited(_setReplayGainEnabled(value));
                    setDialogState(() {});
                  },
                ),
                if (_crossfade)
                  Row(
                    children: [
                      const Text('1s', style: TextStyle(color: Colors.white38)),
                      Expanded(
                        child: Slider(
                          value: _crossfadeSeconds.toDouble(),
                          min: 1,
                          max: 12,
                          divisions: 11,
                          label: '${_crossfadeSeconds}s',
                          onChanged: (value) {
                            setState(() => _crossfadeSeconds = value.round());
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
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
              Text('${selected.toStringAsFixed(2)}×'),
              Slider(
                value: selected,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: '${selected.toStringAsFixed(2)}×',
                onChanged: (value) {
                  selected = value;
                  setDialogState(() {});
                  unawaited(_setPlaybackSpeed(value));
                },
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final speed in [0.5, 1.0, 1.25, 1.5, 2.0])
                    OutlinedButton(
                      onPressed: () {
                        selected = speed;
                        setDialogState(() {});
                        unawaited(_setPlaybackSpeed(speed));
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

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _resumeSaveTimer?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _searchController.dispose();
    _pulse.dispose();
    _player.dispose();
    unawaited(_dspPlayer.dispose());
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
            if (_dspActive) {
              _dspPlayer.setVolume(_volumeFor(_current));
            } else {
              _player.setVolume(_volumeFor(_current));
            }
            _saveQueue();
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
    padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
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
        if (MediaQuery.sizeOf(context).width >= 1000) ...[
          _topAction(Icons.equalizer, 'Visuals'),
          const SizedBox(width: 8),
          _topAction(Icons.settings_outlined, 'Settings'),
          const SizedBox(width: 16),
        ],
        FilledButton.icon(
          onPressed: _addFiles,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add music'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffef4bff),
            foregroundColor: Colors.white,
          ),
        ),
        if (MediaQuery.sizeOf(context).width >= 1000)
          IconButton(
            tooltip: 'Add folder',
            onPressed: _addFolder,
            icon: const Icon(
              Icons.create_new_folder_outlined,
              color: Colors.white60,
            ),
          ),
        if (MediaQuery.sizeOf(context).width >= 1000)
          IconButton(
            tooltip: 'Import audio CD',
            onPressed: _importAudioCd,
            icon: const Icon(Icons.album_outlined, color: Colors.white60),
          ),
        if (MediaQuery.sizeOf(context).width >= 1000)
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
        IconButton(
          tooltip: 'Rescan library folders',
          onPressed: _rescanFolders,
          icon: const Icon(Icons.refresh, color: Colors.white60),
        ),
        if (MediaQuery.sizeOf(context).width >= 1000) ...[
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
            tooltip: 'Import M3U or PLS playlist',
            onPressed: _importPlaylist,
            icon: const Icon(Icons.file_open_outlined, color: Colors.white60),
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
              if (value == 'stream') _addStream();
              if (value == 'radio') _searchRadioDirectory();
              if (value == 'podcast') _addPodcastFeed();
              if (value == 'refreshPodcasts') _refreshPodcasts();
              if (value == 'eq') _showEqualizer();
              if (value == 'speed') _showPlaybackSpeed();
              if (value == 'theme') _showThemePicker();
              if (value == 'importSkin') _importSkin();
              if (value == 'plugins') _showPluginManager();
              if (value == 'export') _exportPlaylist();
              if (value == 'sync') _syncToDeviceFolder();
              if (value == 'cd') _importAudioCd();
              if (value == 'sleep') _showSleepTimer();
              if (value == 'exportPls') _exportPlsPlaylist();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'visuals', child: Text('Visuals')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
              PopupMenuItem(value: 'folder', child: Text('Add folder')),
              PopupMenuItem(
                value: 'rescan',
                child: Text('Rescan library folders'),
              ),
              PopupMenuItem(
                value: 'import',
                child: Text('Import M3U or PLS playlist'),
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
              PopupMenuItem(value: 'eq', child: Text('Equalizer')),
              PopupMenuItem(value: 'speed', child: Text('Playback speed')),
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
              PopupMenuItem(value: 'cd', child: Text('Import audio CD')),
              PopupMenuItem(value: 'sleep', child: Text('Sleep timer')),
              PopupMenuItem(
                value: 'exportPls',
                child: Text('Export PLS playlist'),
              ),
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
      Expanded(child: _heroPanel()),
      SizedBox(height: 220, child: _queuePanel()),
    ],
  );

  Widget _queuePanel() => Container(
    margin: const EdgeInsets.fromLTRB(24, 8, 12, 12),
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
                    _saveQueue();
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
                    _saveQueue();
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
              : _activeView == 'playlists'
              ? _playlistView()
              : _activeView == 'history'
              ? _historyView()
              : _queue.isEmpty
              ? _emptyQueue()
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: _queue.length,
                  onReorder: _reorderQueue,
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
              if (!track.path.startsWith('http'))
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
              if (track.album == 'Podcast' && track.path.startsWith('http'))
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
              final path = _playHistory[index];
              final track = _library.firstWhere(
                (item) => item.path == path,
                orElse: () =>
                    Track(path: path, name: path.split(RegExp(r'[/\\]')).last),
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
                      onTap: () {
                        setState(() {
                          _queue
                            ..clear()
                            ..addAll(
                              _playlists[name]!.map(
                                (path) => _library.firstWhere(
                                  (track) => track.path == path,
                                  orElse: () => Track(
                                    path: path,
                                    name: path.split(RegExp(r'[/\\]')).last,
                                  ),
                                ),
                              ),
                            );
                          _selected = 0;
                        });
                      },
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
      key: ValueKey(track.path),
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

  Widget _heroPanel() => AnimatedBuilder(
    animation: _pulse,
    builder: (_, __) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 24, 12),
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
              padding: const EdgeInsets.all(32),
              child: Column(
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
                        _isPlaying ? Icons.waves : Icons.pause_circle_outline,
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
                              errorBuilder: (_, __, ___) => CustomPaint(
                                size: const Size(double.infinity, 160),
                                painter: SpectrumPainter(
                                  progress: _pulse.value,
                                  active: _isPlaying,
                                ),
                              ),
                            ),
                          )
                        : CustomPaint(
                            size: const Size(double.infinity, 160),
                            painter: SpectrumPainter(
                              progress: _pulse.value,
                              active: _isPlaying,
                            ),
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
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
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
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
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
          ],
        ),
        Row(
          children: [
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
                  _repeatOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
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
                  onChanged: (value) {
                    setState(() => _volume = value);
                    if (_dspActive) {
                      _dspPlayer.setVolume(_volumeFor(_current));
                    } else {
                      _player.setVolume(_volumeFor(_current));
                    }
                  },
                  activeColor: Colors.white70,
                  inactiveColor: Colors.white12,
                ),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

class SpectrumPainter extends CustomPainter {
  const SpectrumPainter({required this.progress, required this.active});
  final double progress;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeCap = StrokeCap.round;
    const count = 52;
    for (var i = 0; i < count; i++) {
      final x = (i + .5) * size.width / count;
      final wave =
          math.sin(i * .66 + progress * math.pi * 2) * .18 +
          math.sin(i * .21 + progress * 4) * .12;
      final normalized = active
          ? (.38 + wave.abs() + (i % 7) * .025)
          : (.12 + (i % 4) * .02);
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
      oldDelegate.progress != progress || oldDelegate.active != active;
}
