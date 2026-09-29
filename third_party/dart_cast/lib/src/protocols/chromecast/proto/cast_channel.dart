/// Hand-written protobuf bindings for the CASTV2 CastMessage.
///
/// These classes mirror the Chromium [?25lcast_channel.proto definition without
/// requiring the protoc compiler.  They use the protobuf packages
/// [GeneratedMessage] / [ProtobufEnum] API directly.
///
/// The CastMessage_* nested-enum type names match the identifiers that
/// protoc --dart_out would emit for the underlying .proto, so the file
/// intentionally opts out of camel_case_types.
// ignore_for_file: camel_case_types
library;

import 'package:protobuf/protobuf.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// CastMessage.ProtocolVersion enum.
class CastMessage_ProtocolVersion extends ProtobufEnum {
  // ignore: constant_identifier_names
  static const CastMessage_ProtocolVersion CASTV2_1_0 =
      CastMessage_ProtocolVersion._(0, 'CASTV2_1_0');

  static const List<CastMessage_ProtocolVersion> values = [CASTV2_1_0];

  static final Map<int, CastMessage_ProtocolVersion> _byValue =
      ProtobufEnum.initByValue(values);

  static CastMessage_ProtocolVersion? valueOf(int value) => _byValue[value];

  const CastMessage_ProtocolVersion._(super.v, super.n);
}

/// CastMessage.PayloadType enum.
class CastMessage_PayloadType extends ProtobufEnum {
  // ignore: constant_identifier_names
  static const CastMessage_PayloadType STRING = CastMessage_PayloadType._(
    0,
    'STRING',
  );
  // ignore: constant_identifier_names
  static const CastMessage_PayloadType BINARY = CastMessage_PayloadType._(
    1,
    'BINARY',
  );

  static const List<CastMessage_PayloadType> values = [STRING, BINARY];

  static final Map<int, CastMessage_PayloadType> _byValue =
      ProtobufEnum.initByValue(values);

  static CastMessage_PayloadType? valueOf(int value) => _byValue[value];

  const CastMessage_PayloadType._(super.v, super.n);
}

// ---------------------------------------------------------------------------
// CastMessage
// ---------------------------------------------------------------------------

/// A manually-coded protobuf GeneratedMessage matching CastMessage from
/// cast_channel.proto.
class CastMessage extends GeneratedMessage {
  factory CastMessage() => CastMessage._();

  factory CastMessage.fromBuffer(
    List<int> bytes, [
    ExtensionRegistry registry = ExtensionRegistry.EMPTY,
  ]) => CastMessage._()..mergeFromBuffer(bytes, registry);

  CastMessage._() : super();

  @override
  CastMessage createEmptyInstance() => CastMessage._();

  @override
  CastMessage clone() => CastMessage._()..mergeFromMessage(this);

  static final BuilderInfo _i =
      BuilderInfo(
          'CastMessage',
          package: const PackageName('extensions.api.cast_channel'),
          createEmptyInstance: CastMessage._,
        )
        ..e<CastMessage_ProtocolVersion>(
          1,
          'protocolVersion',
          PbFieldType.QE,
          defaultOrMaker: CastMessage_ProtocolVersion.CASTV2_1_0,
          valueOf: CastMessage_ProtocolVersion.valueOf,
          enumValues: CastMessage_ProtocolVersion.values,
        )
        ..aQS(2, 'sourceId')
        ..aQS(3, 'destinationId')
        ..aQS(4, 'namespace')
        ..e<CastMessage_PayloadType>(
          5,
          'payloadType',
          PbFieldType.QE,
          defaultOrMaker: CastMessage_PayloadType.STRING,
          valueOf: CastMessage_PayloadType.valueOf,
          enumValues: CastMessage_PayloadType.values,
        )
        ..aOS(6, 'payloadUtf8')
        ..a<List<int>>(7, 'payloadBinary', PbFieldType.OY);

  @override
  BuilderInfo get info_ => _i;

  CastMessage_ProtocolVersion get protocolVersion =>
      getField(1) as CastMessage_ProtocolVersion;
  set protocolVersion(CastMessage_ProtocolVersion v) => setField(1, v);
  bool hasProtocolVersion() => hasField(1);

  String get sourceId => getField(2) as String;
  set sourceId(String v) => setField(2, v);
  bool hasSourceId() => hasField(2);

  String get destinationId => getField(3) as String;
  set destinationId(String v) => setField(3, v);
  bool hasDestinationId() => hasField(3);

  String get namespace_ => getField(4) as String;
  set namespace_(String v) => setField(4, v);
  bool hasNamespace_() => hasField(4);

  CastMessage_PayloadType get payloadType =>
      getField(5) as CastMessage_PayloadType;
  set payloadType(CastMessage_PayloadType v) => setField(5, v);
  bool hasPayloadType() => hasField(5);

  String get payloadUtf8 => getField(6) as String;
  set payloadUtf8(String v) => setField(6, v);
  bool hasPayloadUtf8() => hasField(6);

  List<int> get payloadBinary => getField(7) as List<int>;
  set payloadBinary(List<int> v) => setField(7, v);
  bool hasPayloadBinary() => hasField(7);
}
