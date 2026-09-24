import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef RemoteStateProvider = Map<String, dynamic> Function();
typedef RemoteCommandHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);

class RemoteCommandServer {
  HttpServer? _server;
  final _sockets = <WebSocket>{};

  int? get port => _server?.port;

  Future<int> start({
    int port = 0,
    required RemoteStateProvider state,
    required RemoteCommandHandler command,
  }) async {
    await stop();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen((request) async {
      request.response.headers
        ..contentType = ContentType.json
        ..set('Access-Control-Allow-Origin', '*');
      if (request.method == 'OPTIONS') {
        request.response
          ..headers.set('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
          ..headers.set('Access-Control-Allow-Headers', 'Content-Type')
          ..statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (request.uri.path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _sockets.add(socket);
        socket.add(jsonEncode({'type': 'state', 'state': state()}));
        socket.listen(
          (message) async {
            final result = await _dispatch(message, command);
            socket.add(jsonEncode(result));
          },
          onDone: () => _sockets.remove(socket),
          onError: (_) => _sockets.remove(socket),
        );
        return;
      }
      if (request.uri.path == '/api/state' && request.method == 'GET') {
        await _writeJson(request.response, {'state': state()});
        return;
      }
      if (request.uri.path == '/api/command' && request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final result = await _dispatch(body, command);
        await _writeJson(request.response, result);
        return;
      }
      if (request.uri.path == '/' && request.method == 'GET') {
        await _writeJson(
          request.response,
          {
            'name': 'NeonAmp remote',
            'stateEndpoint': '/api/state',
            'commandEndpoint': '/api/command',
            'websocketEndpoint': '/ws',
          },
        );
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    return server.port;
  }

  Future<Map<String, dynamic>> _dispatch(
    Object message,
    RemoteCommandHandler command,
  ) async {
    try {
      final decoded = message is Map<String, dynamic>
          ? message
          : jsonDecode(message.toString());
      if (decoded is! Map) throw const FormatException('Expected a JSON object');
      final result = await command(Map<String, dynamic>.from(decoded));
      return {'ok': true, 'result': result};
    } on Object catch (error) {
      return {'ok': false, 'error': error.toString()};
    }
  }

  void broadcastState(Map<String, dynamic> state) {
    final message = jsonEncode({'type': 'state', 'state': state});
    for (final socket in List<WebSocket>.from(_sockets)) {
      socket.add(message);
    }
  }

  Future<void> stop() async {
    for (final socket in List<WebSocket>.from(_sockets)) {
      await socket.close();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
