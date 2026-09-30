import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/network_library.dart';

void main() {
  test('recognizes supported network audio paths only', () {
    expect(isNetworkLibraryAudioPath('Music/Live.FLAC'), isTrue);
    expect(isNetworkLibraryAudioPath('Music/cover.jpg'), isFalse);
  });

  test('round-trips SMB and NFS profile settings', () {
    final profile = NetworkLibraryProfile(
      id: 'nas',
      name: 'Living room NAS',
      kind: 'smb',
      host: '192.168.1.10',
      root: 'Music',
      username: 'dj',
      password: 'secret',
    );
    expect(
      NetworkLibraryProfile.fromJson(profile.toJson()).toJson(),
      profile.toJson(),
    );
  });
}
