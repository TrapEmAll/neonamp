/// Reads podcast feed URLs from common OPML 2.0 outline elements.
List<String> podcastFeedsFromOpml(String opml) {
  final feeds = <String>{};
  final outlinePattern = RegExp(r'<outline\b([^>]*)>', caseSensitive: false);
  final attributePattern = RegExp(
    r'''([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  );
  for (final outline in outlinePattern.allMatches(opml)) {
    final attributes = <String, String>{};
    for (final attribute in attributePattern.allMatches(outline.group(1)!)) {
      final value = attribute.group(2) ?? attribute.group(3) ?? '';
      attributes[attribute.group(1)!.toLowerCase()] = _xmlUnescape(value);
    }
    final url = attributes['xmlurl']?.trim();
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      feeds.add(uri.toString());
    }
  }
  return feeds.toList(growable: false);
}

/// Serializes feed URLs as an interoperable OPML 2.0 document.
String podcastFeedsToOpml(Iterable<String> feeds) {
  final outlines = feeds
      .toSet()
      .map((feed) {
        final escaped = _xmlEscape(feed);
        return '    <outline type="rss" text="$escaped" title="$escaped" xmlUrl="$escaped" />';
      })
      .join('\n');
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<opml version="2.0">\n'
      '  <head><title>NeonAmp Podcasts</title></head>\n'
      '  <body>\n$outlines\n  </body>\n'
      '</opml>\n';
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll("'", '&apos;');

String _xmlUnescape(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
