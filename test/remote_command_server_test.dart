import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/remote_command_server.dart';

void main() {
  test('serves state and dispatches HTTP commands', () async {
    final server = RemoteCommandServer();
    final port = await server.start(
      state: () => {'playing': false},
      command: (command) async => {'received': command['type']},
    );
    final client = HttpClient();
    try {
      final page = await (await client.get('127.0.0.1', port, '/')).close();
      final pageBody = await page.transform(utf8.decoder).join();
      expect(page.statusCode, HttpStatus.ok);
      expect(pageBody, contains('Play / pause'));
      expect(pageBody, contains('/api/command'));

      final state = await (await client.get('127.0.0.1', port, '/api/state')).close();
      expect(state.statusCode, HttpStatus.ok);
      expect(jsonDecode(await state.transform(utf8.decoder).join())['state']['playing'], false);

      final request = await client.post('127.0.0.1', port, '/api/command');
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'type': 'next'}));
      final response = await request.close();
      final decoded = jsonDecode(await response.transform(utf8.decoder).join());
      expect(decoded['ok'], true);
      expect(decoded['result']['received'], 'next');
    } finally {
      client.close(force: true);
      await server.stop();
    }
  });
}
