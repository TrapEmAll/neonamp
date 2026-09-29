import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/airplay_cast.dart';

void main() {
  CastDevice device(Map<String, String> metadata) => CastDevice(
    id: 'receiver',
    name: 'Receiver',
    protocol: CastProtocol.airplay,
    address: InternetAddress('192.168.1.10'),
    port: 7000,
    metadata: metadata,
  );

  test('keeps AirPlay receivers advertising audio support', () {
    expect(
      airPlayDeviceSupportsAudio(device({'features': '0x200'})),
      isTrue,
    );
  });

  test('hides AirPlay advertisements without audio support', () {
    expect(
      airPlayDeviceSupportsAudio(device({'features': '0x1'})),
      isFalse,
    );
  });

  test('keeps receivers with missing feature TXT records', () {
    expect(airPlayDeviceSupportsAudio(device({})), isTrue);
  });
}

