import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

const _headerGuid = <int>[
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
const _contentDescriptionGuid = <int>[
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
const _extendedContentDescriptionGuid = <int>[
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
const _filePropertiesGuid = <int>[
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
const _headerExtensionGuid = <int>[
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
const _metadataObjectGuid = <int>[
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
const _reservedHeaderExtensionGuid = <int>[
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

const _contentFields = [
  'Title',
  'Author',
  'Copyright',
  'Description',
  'Rating',
];
const _managedDescriptors = {
  'WM/AlbumTitle',
  'WM/Genre',
  'WM/Year',
  'WM/TrackNumber',
  'WM/PartOfSet',
  'WM/Lyrics',
};

class _AsfObject {
  const _AsfObject(this.guid, this.start, this.dataStart, this.end);
  final List<int> guid;
  final int start;
  final int dataStart;
  final int end;
}

class _AsfDescriptor {
  const _AsfDescriptor(this.name, this.type, this.value);
  final String name;
  final int type;
  final List<int> value;
}

class _AsfMetadataRecord extends _AsfDescriptor {
  const _AsfMetadataRecord(
    super.name,
    super.type,
    super.value,
    this.language,
    this.stream,
  );
  final int language;
  final int stream;
}

int? _u16(Uint8List bytes, int offset, [int? end]) {
  if (offset < 0 || offset + 2 > (end ?? bytes.length)) return null;
  return ByteData.sublistView(bytes).getUint16(offset, Endian.little);
}

int? _u32(Uint8List bytes, int offset, [int? end]) {
  if (offset < 0 || offset + 4 > (end ?? bytes.length)) return null;
  return ByteData.sublistView(bytes).getUint32(offset, Endian.little);
}

int? _u64(Uint8List bytes, int offset, [int? end]) {
  if (offset < 0 || offset + 8 > (end ?? bytes.length)) return null;
  final value = ByteData.sublistView(bytes).getUint64(offset, Endian.little);
  if (value > 0x7fffffffffffffff) return null;
  return value;
}

Uint8List _readAsfHeaderSync(File file) {
  final reader = file.openSync();
  try {
    const maxHeaderLength = 16 * 1024 * 1024;
    if (reader.lengthSync() < 24) {
      throw const FormatException('Truncated ASF Header Object');
    }
    final prefix = Uint8List.fromList(reader.readSync(24));
    if (!_sameBytes(prefix.sublist(0, 16), _headerGuid)) {
      throw const FormatException('Not an ASF file');
    }
    final headerLength = _u64(prefix, 16);
    if (headerLength == null ||
        headerLength < 30 ||
        headerLength > maxHeaderLength ||
        headerLength > reader.lengthSync()) {
      throw const FormatException('Invalid ASF Header Object size');
    }
    reader.setPositionSync(0);
    final header = Uint8List.fromList(reader.readSync(headerLength));
    if (header.length != headerLength) {
      throw const FormatException('Truncated ASF Header Object');
    }
    return header;
  } finally {
    reader.closeSync();
  }
}

Map<String, String> readAsfFieldsFromFile(File file) =>
    readAsfFields(_readAsfHeaderSync(file));

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> _le64(int value) => [
  ..._le32(value & 0xffffffff),
  ..._le32(value >> 32),
];

String _decodeUtf16(List<int> bytes) {
  var end = bytes.length;
  if (end.isOdd) end--;
  if (end >= 2 && bytes[end - 2] == 0 && bytes[end - 1] == 0) end -= 2;
  final codePoints = <int>[];
  for (var offset = 0; offset < end; offset += 2) {
    final first = bytes[offset] | (bytes[offset + 1] << 8);
    if (first >= 0xd800 && first <= 0xdbff && offset + 3 < end) {
      final second = bytes[offset + 2] | (bytes[offset + 3] << 8);
      if (second >= 0xdc00 && second <= 0xdfff) {
        codePoints.add(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00);
        offset += 2;
        continue;
      }
    }
    codePoints.add(first);
  }
  return String.fromCharCodes(codePoints);
}

List<int> _encodeUtf16(String value) => [
  for (final rune in value.runes)
    if (rune <= 0xffff) ...[
      rune & 0xff,
      (rune >> 8) & 0xff,
    ] else ...[
      ..._utf16Unit(0xd800 + ((rune - 0x10000) >> 10)),
      ..._utf16Unit(0xdc00 + ((rune - 0x10000) & 0x3ff)),
    ],
  0,
  0,
];

List<int> _utf16Unit(int value) => [value & 0xff, (value >> 8) & 0xff];

_AsfObject _readObject(Uint8List bytes, int start, int parentEnd) {
  if (start < 0 || start + 24 > parentEnd || parentEnd > bytes.length) {
    throw const FormatException('Truncated ASF object header');
  }
  final size = _u64(bytes, start + 16, parentEnd);
  if (size == null || size < 24 || size > parentEnd - start) {
    throw const FormatException('Invalid ASF object size');
  }
  return _AsfObject(
    bytes.sublist(start, start + 16),
    start,
    start + 24,
    start + size,
  );
}

List<_AsfObject> _readHeaderObjects(Uint8List bytes, _AsfObject header) {
  if (header.guid.length != 16 || header.dataStart + 6 > header.end) {
    throw const FormatException('Malformed ASF Header Object');
  }
  final count = _u32(bytes, header.dataStart, header.end);
  if (count == null) throw const FormatException('Missing ASF object count');
  var offset = header.dataStart + 6;
  final objects = <_AsfObject>[];
  for (var i = 0; i < count; i++) {
    final object = _readObject(bytes, offset, header.end);
    objects.add(object);
    offset = object.end;
  }
  if (offset != header.end) {
    throw const FormatException('ASF Header object count does not match size');
  }
  return objects;
}

Map<String, String> _readContentDescription(
  Uint8List bytes,
  _AsfObject object,
) {
  final fields = <String, String>{};
  if (object.end - object.dataStart < 10) {
    throw const FormatException('Truncated ASF Content Description Object');
  }
  var offset = object.dataStart;
  final lengths = <int>[];
  for (var i = 0; i < 5; i++) {
    final length = _u16(bytes, offset, object.end);
    if (length == null) {
      throw const FormatException('Malformed ASF content field length');
    }
    lengths.add(length);
    offset += 2;
  }
  for (var i = 0; i < lengths.length; i++) {
    final end = offset + lengths[i];
    if (end > object.end) {
      throw const FormatException('ASF content field exceeds object');
    }
    fields[_contentFields[i]] = _decodeUtf16(bytes.sublist(offset, end));
    offset = end;
  }
  if (offset != object.end) {
    throw const FormatException('Unexpected ASF content description data');
  }
  return fields;
}

List<_AsfDescriptor> _readDescriptors(Uint8List bytes, _AsfObject object) {
  final count = _u16(bytes, object.dataStart, object.end);
  if (count == null) {
    throw const FormatException('Missing ASF descriptor count');
  }
  var offset = object.dataStart + 2;
  final descriptors = <_AsfDescriptor>[];
  for (var i = 0; i < count; i++) {
    final nameLength = _u16(bytes, offset, object.end);
    if (nameLength == null) {
      throw const FormatException('Malformed ASF descriptor name length');
    }
    offset += 2;
    if (offset + nameLength > object.end) {
      throw const FormatException('ASF descriptor name exceeds object');
    }
    final name = _decodeUtf16(bytes.sublist(offset, offset + nameLength));
    offset += nameLength;
    final type = _u16(bytes, offset, object.end);
    final valueLength = _u16(bytes, offset + 2, object.end);
    if (type == null || valueLength == null) {
      throw const FormatException('Malformed ASF descriptor header');
    }
    offset += 4;
    if (offset + valueLength > object.end) {
      throw const FormatException('ASF descriptor value exceeds object');
    }
    descriptors.add(
      _AsfDescriptor(name, type, bytes.sublist(offset, offset + valueLength)),
    );
    offset += valueLength;
  }
  if (offset != object.end) {
    throw const FormatException('Unexpected ASF descriptor data');
  }
  return descriptors;
}

List<_AsfMetadataRecord> _readMetadataRecords(
  Uint8List bytes,
  _AsfObject object,
) {
  final count = _u16(bytes, object.dataStart, object.end);
  if (count == null) {
    throw const FormatException('Missing ASF metadata record count');
  }
  var offset = object.dataStart + 2;
  final records = <_AsfMetadataRecord>[];
  for (var i = 0; i < count; i++) {
    final language = _u16(bytes, offset, object.end);
    final stream = _u16(bytes, offset + 2, object.end);
    final nameLength = _u16(bytes, offset + 4, object.end);
    final type = _u16(bytes, offset + 6, object.end);
    final valueLength = _u32(bytes, offset + 8, object.end);
    if (language == null ||
        stream == null ||
        nameLength == null ||
        type == null ||
        valueLength == null) {
      throw const FormatException('Malformed ASF metadata record header');
    }
    offset += 12;
    if (offset + nameLength + valueLength > object.end) {
      throw const FormatException('ASF metadata record exceeds object');
    }
    final name = _decodeUtf16(bytes.sublist(offset, offset + nameLength));
    offset += nameLength;
    records.add(
      _AsfMetadataRecord(
        name,
        type,
        bytes.sublist(offset, offset + valueLength),
        language,
        stream,
      ),
    );
    offset += valueLength;
  }
  if (offset != object.end) {
    throw const FormatException('Unexpected ASF metadata record data');
  }
  return records;
}

List<int> _buildMetadataObject(List<_AsfMetadataRecord> records) {
  if (records.length > 0xffff) {
    throw const FormatException('Too many ASF metadata records');
  }
  return _asfObject(_metadataObjectGuid, [
    ..._le16(records.length),
    for (final record in records) ...[
      ..._le16(record.language),
      ..._le16(record.stream),
      ..._le16(_encodeUtf16(record.name).length),
      ..._le16(record.type),
      ..._le32(record.value.length),
      ..._encodeUtf16(record.name),
      ...record.value,
    ],
  ]);
}

List<int> _rewriteHeaderExtensionForArtwork(
  Uint8List bytes,
  _AsfObject? object,
  Uint8List artwork,
  String mimeType,
) {
  final extensionChildren = <int>[];
  final records = <_AsfMetadataRecord>[];
  List<int> fixedHeader;
  if (object == null) {
    fixedHeader = [..._reservedHeaderExtensionGuid, 6, 0];
  } else {
    if (object.end - object.dataStart < 22) {
      throw const FormatException('Truncated ASF Header Extension Object');
    }
    fixedHeader = bytes.sublist(object.dataStart, object.dataStart + 22);
    final extensionDataSize = _u32(bytes, object.dataStart + 18, object.end);
    if (extensionDataSize == null ||
        extensionDataSize != object.end - object.dataStart - 22) {
      throw const FormatException('Malformed ASF Header Extension data size');
    }
    var offset = object.dataStart + 22;
    while (offset < object.end) {
      final child = _readObject(bytes, offset, object.end);
      if (_sameBytes(child.guid, _metadataObjectGuid)) {
        for (final record in _readMetadataRecords(bytes, child)) {
          if (record.name != 'WM/Picture') records.add(record);
        }
      } else {
        extensionChildren.addAll(bytes.sublist(child.start, child.end));
      }
      offset = child.end;
    }
  }
  records.add(
    _AsfMetadataRecord(
      'WM/Picture',
      1,
      _buildPictureDescriptor(artwork, mimeType),
      0,
      0,
    ),
  );
  extensionChildren.addAll(_buildMetadataObject(records));
  final extensionPayload = [
    ...fixedHeader.sublist(0, 18),
    ..._le32(extensionChildren.length),
    ...extensionChildren,
  ];
  return _asfObject(_headerExtensionGuid, extensionPayload);
}

String? _descriptorString(_AsfDescriptor descriptor) {
  switch (descriptor.type) {
    case 0:
      return _decodeUtf16(descriptor.value);
    case 1:
      return null;
    case 2:
      if (descriptor.value.length != 4) return null;
      return _u32(Uint8List.fromList(descriptor.value), 0) == 0
          ? 'false'
          : 'true';
    case 3:
      if (descriptor.value.length != 4) return null;
      return _u32(Uint8List.fromList(descriptor.value), 0).toString();
    case 4:
      if (descriptor.value.length != 8) return null;
      return _u64(Uint8List.fromList(descriptor.value), 0).toString();
    case 5:
      if (descriptor.value.length != 2) return null;
      return _u16(Uint8List.fromList(descriptor.value), 0).toString();
    default:
      return null;
  }
}

(List<int>, String)? _pictureBytes(_AsfDescriptor descriptor) {
  if (descriptor.type != 1 || descriptor.value.length < 7) return null;
  final bytes = Uint8List.fromList(descriptor.value);
  final dataLength = _u32(bytes, 1);
  if (dataLength == null) return null;
  var offset = 5;
  String? readNullTerminatedString() {
    final start = offset;
    while (offset + 1 < bytes.length) {
      if (bytes[offset] == 0 && bytes[offset + 1] == 0) {
        final value = _decodeUtf16(bytes.sublist(start, offset));
        offset += 2;
        return value;
      }
      offset += 2;
    }
    return null;
  }

  final mimeType = readNullTerminatedString();
  if (mimeType == null || readNullTerminatedString() == null) return null;
  if (dataLength != bytes.length - offset) return null;
  return (bytes.sublist(offset), mimeType);
}

List<int> _buildPictureDescriptor(List<int> image, String mimeType) => [
  3,
  ..._le32(image.length),
  ..._encodeUtf16(mimeType),
  ..._encodeUtf16(''),
  ...image,
];

Map<String, String> readAsfFields(Uint8List bytes) {
  final header = _readObject(bytes, 0, bytes.length);
  if (!_sameBytes(header.guid, _headerGuid)) {
    throw const FormatException('Not an ASF file');
  }
  final result = <String, String>{};
  for (final object in _readHeaderObjects(bytes, header)) {
    if (_sameBytes(object.guid, _contentDescriptionGuid)) {
      result.addAll(_readContentDescription(bytes, object));
    } else if (_sameBytes(object.guid, _extendedContentDescriptionGuid)) {
      for (final descriptor in _readDescriptors(bytes, object)) {
        final value = _descriptorString(descriptor);
        if (value != null) result[descriptor.name] = value;
      }
    }
  }
  for (final extension in _readHeaderObjects(bytes, header)) {
    if (!_sameBytes(extension.guid, _headerExtensionGuid)) continue;
    final extensionDataSize = _u32(
      bytes,
      extension.dataStart + 18,
      extension.end,
    );
    if (extensionDataSize == null ||
        extensionDataSize != extension.end - extension.dataStart - 22) {
      throw const FormatException('Malformed ASF Header Extension data size');
    }
    var offset = extension.dataStart + 22;
    while (offset < extension.end) {
      final child = _readObject(bytes, offset, extension.end);
      if (_sameBytes(child.guid, _metadataObjectGuid)) {
        for (final record in _readMetadataRecords(bytes, child)) {
          final value = _descriptorString(record);
          if (value != null) result[record.name] = value;
        }
      }
      offset = child.end;
    }
  }
  return result;
}

AudioMetadata readAsfMetadata(File file, {bool getImage = false}) {
  final bytes = _readAsfHeaderSync(file);
  final fields = readAsfFields(bytes);
  final year = int.tryParse(fields['WM/Year'] ?? '');
  final trackAndTotal = _numberPair(fields['WM/TrackNumber']);
  final discAndTotal = _numberPair(fields['WM/PartOfSet']);
  final metadata = AudioMetadata(
    file: file,
    title: _nonEmpty(fields['Title']),
    artist: _nonEmpty(fields['Author']),
    album: _nonEmpty(fields['WM/AlbumTitle']),
    year: year == null ? null : DateTime(year),
    trackNumber: trackAndTotal.$1,
    trackTotal: trackAndTotal.$2,
    discNumber: discAndTotal.$1,
    totalDisc: discAndTotal.$2,
    lyrics: _nonEmpty(fields['WM/Lyrics']),
  );
  final genre = _nonEmpty(fields['WM/Genre']);
  if (genre != null) metadata.genres.add(genre);
  if (getImage) {
    final header = _readObject(bytes, 0, bytes.length);
    final picture = _findAsfPicture(bytes, _readHeaderObjects(bytes, header));
    if (picture != null) {
      metadata.pictures.add(
        Picture(
          Uint8List.fromList(picture.$1),
          picture.$2,
          PictureType.coverFront,
        ),
      );
    }
  }
  return metadata;
}

(List<int>, String)? _findAsfPicture(
  Uint8List bytes,
  List<_AsfObject> objects,
) {
  for (final object in objects) {
    if (_sameBytes(object.guid, _extendedContentDescriptionGuid)) {
      for (final descriptor in _readDescriptors(bytes, object)) {
        if (descriptor.name == 'WM/Picture') {
          final picture = _pictureBytes(descriptor);
          if (picture != null) return picture;
        }
      }
    }
  }
  for (final extension in objects) {
    if (!_sameBytes(extension.guid, _headerExtensionGuid)) continue;
    final extensionDataSize = _u32(
      bytes,
      extension.dataStart + 18,
      extension.end,
    );
    if (extensionDataSize == null ||
        extensionDataSize != extension.end - extension.dataStart - 22) {
      throw const FormatException('Malformed ASF Header Extension data size');
    }
    var offset = extension.dataStart + 22;
    while (offset < extension.end) {
      final child = _readObject(bytes, offset, extension.end);
      if (_sameBytes(child.guid, _metadataObjectGuid)) {
        for (final record in _readMetadataRecords(bytes, child)) {
          if (record.name != 'WM/Picture') continue;
          final picture = _pictureBytes(record);
          if (picture != null) return picture;
        }
      }
      offset = child.end;
    }
  }
  return null;
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

(int?, int?) _numberPair(String? raw) {
  if (raw == null) return (null, null);
  final parts = raw.split('/');
  return (
    int.tryParse(parts[0]),
    parts.length > 1 ? int.tryParse(parts[1]) : null,
  );
}

List<int> _contentDescriptionBytes(
  Uint8List bytes,
  List<_AsfObject> objects,
  List<String> values,
) {
  final existing = <String, String>{};
  for (final object in objects) {
    if (_sameBytes(object.guid, _contentDescriptionGuid)) {
      existing.addAll(_readContentDescription(bytes, object));
    }
  }
  final replacements = <String, String>{
    'Title': values[0],
    'Author': values[1],
  };
  final fields = [
    for (final name in _contentFields)
      _encodeUtf16(replacements[name] ?? existing[name] ?? ''),
  ];
  if (fields.any((field) => field.length > 0xffff)) {
    throw const FormatException('An ASF content field exceeds 64 KiB');
  }
  final payload = <int>[
    for (final field in fields) ..._le16(field.length),
    for (final field in fields) ...field,
  ];
  return _asfObject(_contentDescriptionGuid, payload);
}

List<int> _extendedDescriptionBytes(
  Uint8List bytes,
  List<_AsfObject> objects,
  List<String> values, {
  bool replaceArtwork = false,
}) {
  final descriptors = <_AsfDescriptor>[];
  for (final object in objects) {
    if (_sameBytes(object.guid, _extendedContentDescriptionGuid)) {
      descriptors.addAll(_readDescriptors(bytes, object));
    }
  }
  final retained = descriptors
      .where(
        (descriptor) =>
            !_managedDescriptors.contains(descriptor.name) &&
            !(replaceArtwork && descriptor.name == 'WM/Picture'),
      )
      .toList();
  final replacements = <String, String>{
    'WM/AlbumTitle': values[2],
    'WM/Genre': values[3],
    'WM/Year': values[5],
    'WM/TrackNumber': _joinedPair(values[6], values[7]),
    'WM/PartOfSet': _joinedPair(values[8], values[9]),
    'WM/Lyrics': values[10],
  };
  for (final entry in replacements.entries) {
    if (entry.value.isNotEmpty) {
      retained.add(_AsfDescriptor(entry.key, 0, _encodeUtf16(entry.value)));
    }
  }
  if (retained.isEmpty &&
      objects.every(
        (object) => !_sameBytes(object.guid, _extendedContentDescriptionGuid),
      )) {
    return const [];
  }
  if (retained.length > 0xffff) {
    throw const FormatException('Too many ASF metadata descriptors');
  }
  if (retained.any(
    (descriptor) =>
        _encodeUtf16(descriptor.name).length > 0xffff ||
        descriptor.value.length > 0xffff,
  )) {
    throw const FormatException('An ASF descriptor exceeds 64 KiB');
  }
  final payload = <int>[
    ..._le16(retained.length),
    for (final descriptor in retained) ...[
      ..._le16(_encodeUtf16(descriptor.name).length),
      ..._encodeUtf16(descriptor.name),
      ..._le16(descriptor.type),
      ..._le16(descriptor.value.length),
      ...descriptor.value,
    ],
  ];
  return _asfObject(_extendedContentDescriptionGuid, payload);
}

String _joinedPair(String primary, String total) =>
    total.isEmpty ? primary : '$primary/$total';

List<int> _asfObject(List<int> guid, List<int> payload) => [
  ...guid,
  ..._le64(24 + payload.length),
  ...payload,
];

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Future<void> writeAsfTags(
  File file,
  List<String> values, {
  Uint8List? artwork,
  String artworkMimeType = 'image/jpeg',
}) async {
  if (values.length != 11) throw ArgumentError.value(values.length, 'values');
  final originalLength = await file.length();
  final source = _readAsfHeaderSync(file);
  final header = _readObject(source, 0, source.length);
  if (!_sameBytes(header.guid, _headerGuid)) {
    throw const FormatException('Not an ASF file');
  }
  final objects = _readHeaderObjects(source, header);
  final content = _contentDescriptionBytes(source, objects, values);
  final hasHeaderExtension = objects.any(
    (object) => _sameBytes(object.guid, _headerExtensionGuid),
  );
  final extended = _extendedDescriptionBytes(
    source,
    objects,
    values,
    replaceArtwork: artwork != null,
  );
  final rewrittenObjects = <int>[];
  var headerExtensionRewritten = false;
  for (final object in objects) {
    if (_sameBytes(object.guid, _contentDescriptionGuid) ||
        _sameBytes(object.guid, _extendedContentDescriptionGuid)) {
      continue;
    }
    if (_sameBytes(object.guid, _filePropertiesGuid)) {
      final preserved = source.sublist(object.start, object.end);
      if (preserved.length >= 48) {
        preserved.setRange(40, 48, _le64(originalLength));
      }
      rewrittenObjects.addAll(preserved);
    } else if (artwork != null &&
        !headerExtensionRewritten &&
        _sameBytes(object.guid, _headerExtensionGuid)) {
      rewrittenObjects.addAll(
        _rewriteHeaderExtensionForArtwork(
          source,
          object,
          artwork,
          artworkMimeType,
        ),
      );
      headerExtensionRewritten = true;
    } else {
      rewrittenObjects.addAll(source.sublist(object.start, object.end));
    }
  }
  if (artwork != null && !headerExtensionRewritten) {
    rewrittenObjects.addAll(
      _rewriteHeaderExtensionForArtwork(source, null, artwork, artworkMimeType),
    );
  }
  rewrittenObjects.addAll(content);
  rewrittenObjects.addAll(extended);
  final objectCount =
      objects.length -
      objects
          .where(
            (object) =>
                _sameBytes(object.guid, _contentDescriptionGuid) ||
                _sameBytes(object.guid, _extendedContentDescriptionGuid),
          )
          .length +
      1 +
      (extended.isEmpty ? 0 : 1) +
      (artwork != null && !hasHeaderExtension ? 1 : 0);
  final headerPayload = <int>[
    ..._le32(objectCount),
    ...source.sublist(header.dataStart + 4, header.dataStart + 6),
    ...rewrittenObjects,
  ];
  final headerBytes = _asfObject(_headerGuid, headerPayload);
  // ASF packet indexes are packet-relative; the media Data Object and packet
  // payloads remain byte-for-byte unchanged when the header is resized.
  final outputLength = originalLength - header.end + headerBytes.length;
  if (outputLength > 0x7fffffffffffffff) {
    throw const FormatException('ASF file is too large to rewrite');
  }
  // Update the ASF File Properties Object with the final file size after the
  // Header Object has changed length.
  final outputBytes = Uint8List.fromList(headerBytes);
  final outputHeader = _readObject(outputBytes, 0, outputBytes.length);
  for (final object in _readHeaderObjects(outputBytes, outputHeader)) {
    if (_sameBytes(object.guid, _filePropertiesGuid) &&
        object.end - object.start >= 48) {
      outputBytes.setRange(
        object.start + 40,
        object.start + 48,
        _le64(outputLength),
      );
      break;
    }
  }
  await _replaceAsfFileAtomically(file, outputBytes, header.end);
}

Future<void> _replaceAsfFileAtomically(
  File file,
  Uint8List headerBytes,
  int sourceOffset,
) async {
  final suffix = '.neonamp-${DateTime.now().microsecondsSinceEpoch}';
  final temporary = File('${file.path}$suffix.tmp');
  final backup = File('${file.path}$suffix.bak');
  var movedOriginal = false;
  try {
    final sink = temporary.openWrite(mode: FileMode.write);
    try {
      sink.add(headerBytes);
      await sink.addStream(file.openRead(sourceOffset));
      await sink.flush();
    } finally {
      await sink.close();
    }
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
