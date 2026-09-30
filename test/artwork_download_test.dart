import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/artwork_download.dart';

void main() {
  late HttpServer server;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(server.forEach((request) {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([1, 2, 3]);
      return request.response.close();
    }));
  });

  tearDown(() => server.close(force: true));

  test('downloads bounded image bytes and keeps image MIME type', () async {
    final result = await downloadArtworkImage('http://127.0.0.1:${server.port}/cover');
    expect(result.bytes, [1, 2, 3]);
    expect(result.mimeType, 'image/png');
  });

  test('rejects non-image URLs', () async {
    await expectLater(
      downloadArtworkImage('http://127.0.0.1:${server.port}/cover', maxBytes: 2),
      throwsA(isA<FormatException>()),
    );
  });
}
