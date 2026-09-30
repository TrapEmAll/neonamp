import 'dart:convert';
import 'dart:io';

String networkCacheFileName(String profileId, String relativePath) {
  final encoded = base64Url
      .encode(utf8.encode('$profileId:$relativePath'))
      .replaceAll('=', '_');
  final normalized = relativePath.replaceAll('\\', '/');
  final dot = normalized.lastIndexOf('.');
  final extension = dot > normalized.lastIndexOf('/')
      ? '.${normalized.substring(dot + 1).toLowerCase()}'
      : '.audio';
  return '$encoded$extension';
}

String networkCachePath(String root, String profileId, String relativePath) =>
    '$root${Platform.pathSeparator}${networkCacheFileName(profileId, relativePath)}';

Future<bool> isUsableNetworkCacheFile(File file) async {
  try {
    return await file.exists() && await file.length() > 44;
  } on Object {
    return false;
  }
}

