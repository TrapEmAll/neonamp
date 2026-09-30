import 'dart:io';
import 'dart:typed_data';

class DownloadedArtwork {
  const DownloadedArtwork({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

Future<DownloadedArtwork> downloadArtworkImage(
  String source, {
  int maxBytes = 8 * 1024 * 1024,
}) async {
  final uri = Uri.tryParse(source.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException('Artwork URL must use HTTP or HTTPS.');
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Artwork request failed with HTTP ${response.statusCode}.');
    }
    final contentLength = response.contentLength;
    if (contentLength > maxBytes) {
      throw const FormatException('Artwork image is larger than the 8 MB limit.');
    }
    final output = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > maxBytes) {
        throw const FormatException('Artwork image is larger than the 8 MB limit.');
      }
      output.add(chunk);
    }
    final bytes = output.takeBytes();
    if (bytes.isEmpty) throw const FormatException('Artwork response was empty.');
    final contentType = response.headers.contentType?.mimeType;
    final mimeType = contentType != null && contentType.startsWith('image/')
        ? contentType
        : _mimeTypeForPath(uri.path);
    if (mimeType == null) {
      throw const FormatException('Artwork response is not a supported image.');
    }
    return DownloadedArtwork(bytes: bytes, mimeType: mimeType);
  } finally {
    client.close(force: true);
  }
}

String? _mimeTypeForPath(String path) {
  switch (path.toLowerCase().split('.').last) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return null;
  }
}
