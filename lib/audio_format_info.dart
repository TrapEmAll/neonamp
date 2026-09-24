import 'dart:math' as math;
import 'dart:typed_data';

class AudioFormatInfo {
  const AudioFormatInfo({
    required this.codec,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.peakDb,
  });

  final String codec;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final double? peakDb;

  String get summary {
    final rate = sampleRate == null ? 'unknown rate' : '${sampleRate} Hz';
    final bits = bitDepth == null ? 'unknown bit depth' : '${bitDepth}-bit';
    final channelLabel = channels == null
        ? 'unknown channels'
        : channels == 1
        ? 'mono'
        : channels == 2
        ? 'stereo'
        : '$channels channels';
    return '$codec · $rate · $bits · $channelLabel';
  }

  Map<String, dynamic> toJson() => {
    'codec': codec,
    if (sampleRate != null) 'sampleRate': sampleRate,
    if (bitDepth != null) 'bitDepth': bitDepth,
    if (channels != null) 'channels': channels,
  };
}

class AudioOutputStatus {
  const AudioOutputStatus({
    required this.backend,
    required this.bitPerfectRequested,
    required this.softwareDspActive,
    this.sourceFormat,
    this.hardwareSampleRate,
    this.hardwareBitDepth,
  });

  final String backend;
  final bool bitPerfectRequested;
  final bool softwareDspActive;
  final AudioFormatInfo? sourceFormat;
  final int? hardwareSampleRate;
  final int? hardwareBitDepth;

  bool get hardwareFormatKnown =>
      hardwareSampleRate != null || hardwareBitDepth != null;

  String get summary {
    final hardware = hardwareFormatKnown
        ? '${hardwareSampleRate ?? '?'} Hz / ${hardwareBitDepth ?? '?'}-bit'
        : 'hardware rate unavailable from current backend';
    final mode = bitPerfectRequested
        ? 'bit-perfect best effort requested'
        : softwareDspActive
        ? 'software DSP active'
        : 'native playback path';
    return '$backend · $mode\nHardware output: $hardware';
  }
}

int _u16(Uint8List bytes, int offset, Endian endian) =>
    ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, endian);

int _u32(Uint8List bytes, int offset, Endian endian) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, endian);

double? _pcmPeakDb(
  Uint8List bytes,
  int start,
  int length,
  int bitDepth,
) {
  if (length <= 0 || start < 0 || start >= bytes.length) return null;
  final end = math.min(bytes.length, start + length);
  double peak = 0;
  if (bitDepth == 8) {
    for (var i = start; i < end; i++) {
      peak = math.max(peak, ((bytes[i] - 128).abs() / 128));
    }
  } else if (bitDepth == 16) {
    for (var i = start; i + 1 < end; i += 2) {
      final sample = ByteData.sublistView(bytes, i, i + 2).getInt16(0, Endian.little);
      peak = math.max(peak, sample.abs() / 32768);
    }
  } else if (bitDepth == 24) {
    for (var i = start; i + 2 < end; i += 3) {
      var sample = bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16);
      if ((sample & 0x800000) != 0) sample -= 0x1000000;
      peak = math.max(peak, sample.abs() / 8388608);
    }
  } else if (bitDepth == 32) {
    for (var i = start; i + 3 < end; i += 4) {
      final sample = ByteData.sublistView(bytes, i, i + 4).getInt32(0, Endian.little);
      peak = math.max(peak, sample.abs() / 2147483648);
    }
  } else {
    return null;
  }
  if (peak <= 0) return null;
  return 20 * math.log(peak) / math.ln10;
}

AudioFormatInfo? parseAudioFormat(
  Uint8List bytes, {
  String path = '',
}) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x66 &&
      bytes[1] == 0x4c &&
      bytes[2] == 0x61 &&
      bytes[3] == 0x43) {
    if (bytes.length < 42) return const AudioFormatInfo(codec: 'FLAC');
    final streamInfo = 8;
    final packed = ByteData.sublistView(bytes, streamInfo + 10, streamInfo + 18)
        .getUint64(0, Endian.big);
    final sampleRate = (packed >> 44) & 0xfffff;
    final channels = ((packed >> 41) & 0x7) + 1;
    final bitDepth = ((packed >> 36) & 0x1f) + 1;
    return AudioFormatInfo(
      codec: 'FLAC',
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
    );
  }

  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x41 &&
      bytes[10] == 0x56 &&
      bytes[11] == 0x45) {
    var offset = 12;
    int? channels;
    int? sampleRate;
    int? bitDepth;
    double? peakDb;
    while (offset + 8 <= bytes.length) {
      final chunk = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = _u32(bytes, offset + 4, Endian.little);
      final start = offset + 8;
      if (start + size > bytes.length) break;
      if (chunk == 'fmt ' && size >= 16) {
        channels = _u16(bytes, start + 2, Endian.little);
        sampleRate = _u32(bytes, start + 4, Endian.little);
        bitDepth = _u16(bytes, start + 14, Endian.little);
      } else if (chunk == 'data' && bitDepth != null) {
        peakDb = _pcmPeakDb(bytes, start, size, bitDepth);
        break;
      }
      offset = start + size + (size.isOdd ? 1 : 0);
    }
    return AudioFormatInfo(
      codec: 'WAV',
      channels: channels,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      peakDb: peakDb,
    );
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x46 &&
      bytes[1] == 0x4f &&
      bytes[2] == 0x52 &&
      bytes[3] == 0x4d) {
    final form = String.fromCharCodes(bytes.sublist(8, 12));
    if (form == 'AIFF' || form == 'AIFC') {
      var offset = 12;
      while (offset + 8 <= bytes.length) {
        final chunk = String.fromCharCodes(bytes.sublist(offset, offset + 4));
        final size = _u32(bytes, offset + 4, Endian.big);
        final start = offset + 8;
        if (start + size > bytes.length) break;
        if (chunk == 'COMM' && size >= 18) {
          return AudioFormatInfo(
            codec: form,
            channels: _u16(bytes, start, Endian.big),
            bitDepth: _u16(bytes, start + 6, Endian.big),
          );
        }
        offset = start + size + (size.isOdd ? 1 : 0);
      }
      return AudioFormatInfo(codec: form);
    }
  }

  if (bytes.length >= 12 &&
      bytes[0] == 0x46 &&
      bytes[1] == 0x52 &&
      bytes[2] == 0x4d &&
      bytes[3] == 0x38 &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'DSD ') {
    var offset = 12;
    int? sampleRate;
    int? channels;
    while (offset + 12 <= bytes.length) {
      final chunk = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = ByteData.sublistView(bytes, offset + 4, offset + 12)
          .getUint64(0, Endian.big);
      final start = offset + 12;
      if (size > bytes.length - start) break;
      final end = start + size;
      if (chunk == 'PROP' && size >= 4) {
        var propertyOffset = start + 4;
        while (propertyOffset + 12 <= end) {
          final property = String.fromCharCodes(
            bytes.sublist(propertyOffset, propertyOffset + 4),
          );
          final propertySize = ByteData.sublistView(
            bytes,
            propertyOffset + 4,
            propertyOffset + 12,
          ).getUint64(0, Endian.big);
          final propertyStart = propertyOffset + 12;
          if (propertySize > end - propertyStart) break;
          if (property == 'FS  ' && propertySize >= 4) {
            sampleRate = _u32(bytes, propertyStart, Endian.big);
          } else if (property == 'CHNL' && propertySize >= 2) {
            channels = _u16(bytes, propertyStart, Endian.big);
          }
          propertyOffset =
              propertyStart + propertySize + (propertySize.isOdd ? 1 : 0);
        }
      }
      offset = end + (size.isOdd ? 1 : 0);
    }
    return AudioFormatInfo(
      codec: 'DSD',
      sampleRate: sampleRate,
      bitDepth: 1,
      channels: channels,
    );
  }

  if (bytes.length >= 36 &&
      bytes[0] == 0x44 &&
      bytes[1] == 0x53 &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x20) {
    var offset = 28;
    while (offset + 8 <= bytes.length) {
      final chunk = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      if (offset + 12 > bytes.length) break;
      final size = ByteData.sublistView(bytes, offset + 4, offset + 12)
          .getUint64(0, Endian.little);
      final start = offset + 12;
      if (size < 12 || start > bytes.length || size - 12 > bytes.length - start) {
        break;
      }
      if (chunk == 'fmt ' && size >= 32 && start + 24 <= bytes.length) {
        return AudioFormatInfo(
          codec: 'DSD',
          channels: _u32(bytes, start + 12, Endian.little),
          sampleRate: _u32(bytes, start + 16, Endian.little),
          bitDepth: _u32(bytes, start + 20, Endian.little),
        );
      }
      offset += size;
    }
  }

  final extension = path.split('.').last.toLowerCase();
  if (extension == 'dsf' || extension == 'dff' || extension == 'dsdiff') {
    return const AudioFormatInfo(codec: 'DSD');
  }
  return null;
}
