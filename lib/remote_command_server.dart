import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef RemoteStateProvider = Map<String, dynamic> Function();
typedef RemoteCommandHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);

const _remoteControlPage = r'''
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NeonAmp Remote</title>
<style>
body{font-family:system-ui;background:#101018;color:#f4f2ff;max-width:520px;margin:0 auto;padding:24px}
button{font-size:1.05rem;padding:12px 16px;margin:4px;border:0;border-radius:10px;background:#e84cff;color:white}
button.secondary{background:#282838}input{width:100%}.card{background:#1b1b28;border-radius:16px;padding:18px;margin:12px 0}
small{color:#aaa}.queue{max-height:260px;overflow:auto}
</style>
</head>
<body>
<h1>NeonAmp Remote</h1>
<div class="card"><strong id="track">Nothing playing</strong><br><small id="artist"></small></div>
<div class="card">
<button class="secondary" onclick="send('previous')">⏮</button>
<button onclick="send('toggle')">Play / pause</button>
<button class="secondary" onclick="send('next')">⏭</button>
<input id="seek" type="range" min="0" max="1" value="0" oninput="seek(this.value)">
<label>Volume <input id="volume" type="range" min="0" max="1" step=".01" value=".8" oninput="volume(this.value)"></label>
</div>
<div class="card"><strong>Queue</strong><button class="secondary" onclick="send('clearQueue')">Clear queue</button><div id="queue" class="queue"></div></div>
<script>
async function send(type,extra={}){await fetch('/api/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({type,...extra})});refresh()}
async function seek(v){send('seek',{positionMs:Math.round(v*1000)})}
async function volume(v){send('volume',{value:Number(v)})}
async function refresh(){const r=await fetch('/api/state');const s=(await r.json()).state||{};const t=s.current||{};document.getElementById('track').textContent=t.title||'Nothing playing';document.getElementById('artist').textContent=t.artist||'';document.getElementById('seek').max=Math.max(1,Math.round((s.durationMs||0)/1000));document.getElementById('seek').value=Math.min(document.getElementById('seek').max,Math.round((s.positionMs||0)/1000));document.getElementById('volume').value=s.volume??.8;document.getElementById('queue').innerHTML=(s.queue||[]).map((x,i)=>'<button class="secondary" onclick="send(\'select\',{index:i})">'+escapeHtml(x.title||'')+'<small> — '+escapeHtml(x.artist||'')+'</small></button>').join('')}
function escapeHtml(x){return x.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
refresh();setInterval(refresh,2000);
</script>
</body>
</html>
''';

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
        request.response.headers.contentType = ContentType.html;
        request.response.write(_remoteControlPage);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });
    return server.port;
  }

  Future<void> _writeJson(
    HttpResponse response,
    Map<String, dynamic> value,
  ) async {
    response.write(jsonEncode(value));
    await response.close();
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
