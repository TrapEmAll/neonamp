import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

class WebDavEntry {
  const WebDavEntry({
    required this.url,
    required this.name,
    required this.isDirectory,
    this.contentType,
    this.size,
  });

  final String url;
  final String name;
  final bool isDirectory;
  final String? contentType;
  final int? size;
}

class WebDavLibraryClient {
  WebDavLibraryClient({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  Future<List<WebDavEntry>> list(
    Uri folder, {
    String? username,
    String? password,
  }) async {
    if (folder.scheme != 'http' && folder.scheme != 'https') {
      throw ArgumentError('A WebDAV HTTP or HTTPS URL is required.');
    }
    if (username?.isNotEmpty == true) {
      _client.addCredentials(
        folder,
        '',
        HttpClientBasicCredentials(username!, password ?? ''),
      );
    }
    final request = await _client.openUrl('PROPFIND', folder);
    request.headers
      ..set('Depth', '1')
      ..contentType = ContentType('application', 'xml', charset: 'utf-8');
    request.write(
      '<?xml version="1.0" encoding="utf-8" ?>'
      '<propfind xmlns="DAV:"><prop>'
      '<displayname/><resourcetype/><getcontenttype/><getcontentlength/>'
      '</prop></propfind>',
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV returned ${response.statusCode}',
        uri: folder,
      );
    }
    return _parseResponse(body, folder);
  }

  Future<List<WebDavEntry>> listRecursive(
    Uri folder, {
    String? username,
    String? password,
    int maxDepth = 12,
  }) async {
    if (maxDepth < 0) {
      throw ArgumentError.value(maxDepth, 'maxDepth');
    }
    final root = folder;
    final pending = <({Uri uri, int depth})>[(uri: folder, depth: 0)];
    final visited = <String>{};
    final entries = <WebDavEntry>[];
    while (pending.isNotEmpty) {
      final current = pending.removeAt(0);
      final key = current.uri.normalizePath().toString();
      if (!visited.add(key)) continue;
      final children = await list(
        current.uri,
        username: username,
        password: password,
      );
      for (final entry in children) {
        final entryUri = Uri.tryParse(entry.url);
        if (entryUri == null || !_sameOrigin(entryUri, root)) continue;
        entries.add(entry);
        if (entry.isDirectory && current.depth < maxDepth) {
          pending.add((uri: entryUri, depth: current.depth + 1));
        }
      }
    }
    return entries;
  }

  List<WebDavEntry> _parseResponse(String body, Uri base) {
    final document = XmlDocument.parse(body);
    final entries = <WebDavEntry>[];
    for (final response in document.descendants.whereType<XmlElement>().where(
      (element) => element.localName == 'response',
    )) {
      final href = _descendantText(response, 'href');
      if (href == null || href.isEmpty) continue;
      final resolved = base.resolve(Uri.decodeFull(href)).toString();
      if (_sameUrl(resolved, base.toString())) continue;
      final resourceType = response.descendants.whereType<XmlElement>().where(
        (element) => element.localName == 'resourcetype',
      );
      final isDirectory = resourceType.any(
        (element) => element.descendants.whereType<XmlElement>().any(
          (child) => child.localName == 'collection',
        ),
      );
      final displayName = _descendantText(response, 'displayname') ??
          Uri.parse(resolved).pathSegments.lastOrNull ??
          resolved;
      final size = int.tryParse(_descendantText(response, 'getcontentlength') ?? '');
      final contentType = _descendantText(response, 'getcontenttype');
      entries.add(
        WebDavEntry(
          url: resolved,
          name: displayName,
          isDirectory: isDirectory,
          contentType: contentType,
          size: size,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  String? _descendantText(XmlElement element, String localName) =>
      element.descendants
          .whereType<XmlElement>()
          .where((child) => child.localName == localName)
          .map((child) => child.innerText.trim())
          .firstWhere((value) => value.isNotEmpty, orElse: () => '');

  bool _sameUrl(String left, String right) =>
      Uri.parse(left).normalizePath().toString() ==
      Uri.parse(right).normalizePath().toString();

  bool _sameOrigin(Uri left, Uri right) =>
      left.scheme.toLowerCase() == right.scheme.toLowerCase() &&
      left.host.toLowerCase() == right.host.toLowerCase() &&
      left.port == right.port;

  void close() => _client.close(force: true);
}
