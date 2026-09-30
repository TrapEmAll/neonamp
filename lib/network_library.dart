import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_nfs/flutter_nfs.dart';

const networkAudioExtensions = <String>{
  'aac',
  'aif',
  'aiff',
  'alac',
  'ape',
  'flac',
  'm4a',
  'm4b',
  'mp3',
  'oga',
  'ogg',
  'opus',
  'wav',
  'wma',
};

bool isNetworkLibraryAudioPath(String path) {
  final name = path.split('/').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot > 0 && networkAudioExtensions.contains(name.substring(dot + 1));
}

class NetworkLibraryProfile {
  const NetworkLibraryProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    required this.root,
    this.username = '',
    this.password = '',
  });

  final String id;
  final String name;
  final String kind;
  final String host;
  final String root;
  final String username;
  final String password;

  bool get isSmb => kind == 'smb';
  bool get isNfs => kind == 'nfs';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'host': host,
    'root': root,
    'username': username,
    'password': password,
  };

  factory NetworkLibraryProfile.fromJson(Map<String, dynamic> json) =>
      NetworkLibraryProfile(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? 'Network library',
        kind: json['kind']?.toString() == 'nfs' ? 'nfs' : 'smb',
        host: json['host']?.toString() ?? '',
        root: json['root']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
      );
}

class NetworkLibraryEntry {
  const NetworkLibraryEntry({
    required this.relativePath,
    required this.name,
    required this.size,
  });

  final String relativePath;
  final String name;
  final int size;
}

class NetworkLibraryClient {
  Future<List<NetworkLibraryEntry>> listRecursive(
    NetworkLibraryProfile profile,
  ) async {
    if (profile.host.trim().isEmpty || profile.root.trim().isEmpty) {
      throw ArgumentError('A network host and share/export are required.');
    }
    return profile.isSmb
        ? _listSmb(profile)
        : profile.isNfs
        ? _listNfs(profile)
        : throw ArgumentError('Unsupported network library type.');
  }

  Future<String> downloadToFile(
    NetworkLibraryProfile profile,
    String relativePath,
    String destinationPath,
  ) async {
    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    if (profile.isSmb) {
      final pool = await Smb2Pool.connect(
        host: profile.host,
        share: profile.root,
        user: profile.username,
        password: profile.password,
        workers: 1,
      );
      try {
        await pool.downloadToFile(relativePath, destination);
      } finally {
        await pool.disconnect();
      }
    } else if (profile.isNfs) {
      final client = NfsClient();
      await client.init();
      await client.mount(_nfsUri(profile));
      final dynamic entry = client;
      final dynamic info = await entry.stat(_nfsPath(relativePath));
      final size = (info.size as num).toInt();
      final bytes = await entry.read(_nfsPath(relativePath), 0, size);
      await destination.writeAsBytes(List<int>.from(bytes), flush: true);
    } else {
      throw ArgumentError('Unsupported network library type.');
    }
    return destination.path;
  }

  Future<List<NetworkLibraryEntry>> _listSmb(
    NetworkLibraryProfile profile,
  ) async {
    final pool = await Smb2Pool.connect(
      host: profile.host,
        share: profile.smbShare,
      user: profile.username,
      password: profile.password,
      workers: 1,
    );
    try {
      final results = <NetworkLibraryEntry>[];
      Future<void> walk(String directory) async {
        final entries = await pool.listDirectory(directory);
        for (final entry in entries) {
          final relative = directory.isEmpty
              ? entry.name
              : '$directory/${entry.name}';
          if (entry.isDirectory) {
            await walk(relative);
          } else if (isNetworkLibraryAudioPath(entry.name)) {
            results.add(
              NetworkLibraryEntry(
                relativePath: relative,
                name: entry.name,
                size: entry.size,
              ),
            );
          }
        }
      }

      await walk(profile.smbPath);
      return results;
    } finally {
      await pool.disconnect();
    }
  }

  Future<List<NetworkLibraryEntry>> _listNfs(
    NetworkLibraryProfile profile,
  ) async {
    final client = NfsClient();
    await client.init();
    await client.mount(_nfsUri(profile));
    final results = <NetworkLibraryEntry>[];
    final dynamic nfs = client;
    Future<void> walk(String directory) async {
      final entries = await nfs.listDir(directory);
      for (final dynamic entry in entries) {
        final name = entry.name.toString();
        final relative = directory == '/' ? name : '$directory/$name';
        if (entry.isDirectory == true) {
          await walk(relative);
        } else if (isNetworkLibraryAudioPath(name)) {
          results.add(
            NetworkLibraryEntry(
              relativePath: relative,
              name: name,
              size: (entry.size as num?)?.toInt() ?? 0,
            ),
          );
        }
      }
    }

    await walk(profile.nfsPath);
    return results;
  }
}

extension on NetworkLibraryProfile {
  String get smbShare => root.split('/').first.trim();

  String get smbPath {
    final parts = root.replaceAll('\\', '/').split('/');
    return parts.length <= 1 ? '' : parts.skip(1).join('/');
  }

  String get nfsPath {
    final value = root.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    return value.isEmpty ? '/' : '/$value';
  }
}

String _nfsUri(NetworkLibraryProfile profile) =>
    'nfs://${profile.host}/${profile.root.replaceAll(RegExp(r'^/+'), '')}';

String _nfsPath(String path) => path.startsWith('/') ? path : '/$path';
