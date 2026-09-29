import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/track_auditor.dart';

void main() {
  test('groups duplicate tracks and recommends the higher quality copy', () {
    final group = findDuplicateAudioGroups([
      const AudioAuditEntry(
        path: 'low.mp3',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        extension: 'mp3',
        bitrateKbps: 128,
      ),
      const AudioAuditEntry(
        path: 'high.flac',
        title: ' song ',
        artist: 'artist',
        album: 'Album',
        extension: 'flac',
        bitrateKbps: 0,
        sizeBytes: 100,
      ),
    ]).single;
    expect(group.recommended.path, 'high.flac');
    expect(group.lowerQuality.single.path, 'low.mp3');
  });

  test('flags sampled sources that reach digital full scale', () {
    final clipped = findClippedTracks([
      const AudioAuditEntry(path: 'clip.wav', title: 'Clip', artist: 'Artist', peakDb: 0),
      const AudioAuditEntry(path: 'safe.wav', title: 'Safe', artist: 'Artist', peakDb: -1.2),
      const AudioAuditEntry(path: 'unknown.mp3', title: 'Unknown', artist: 'Artist'),
    ]);
    expect(clipped.map((entry) => entry.path), ['clip.wav']);
  });

  test('flags missing core tags', () {
    expect(
      findMissingCoreTags([
        const AudioAuditEntry(path: 'a.mp3', title: 'Song', artist: ''),
      ]).single.path,
      'a.mp3',
    );
  });
}
