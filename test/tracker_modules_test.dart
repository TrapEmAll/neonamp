import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/main.dart';
import 'package:neonamp/tracker_modules.dart';

void main() {
  test('tracker module extensions are recognized for library scans', () {
    for (final extension in trackerModuleExtensions) {
      expect(isTrackerModulePath('music.$extension'), isTrue);
      expect(isSupportedLibraryAudioPath('C:/Music/music.$extension'), isTrue);
    }
    expect(isTrackerModulePath('music.MoD'), isTrue);
    expect(isTrackerModulePath('music.mp3'), isFalse);
    expect(isSupportedLibraryAudioPath('C:/Music/video.mp4'), isTrue);
    expect(isSupportedLibraryAudioPath('C:/Music/audiobook.m4b'), isTrue);
    expect(isSupportedLibraryAudioPath('C:/Music/readme.txt'), isFalse);
  });

  test('MIDI and karaoke MIDI files are recognized for library scans', () {
    for (final extension in midiFileExtensions) {
      expect(isMidiFilePath('C:/Music/song.$extension'), isTrue);
      expect(isSupportedLibraryAudioPath('C:/Music/song.$extension'), isTrue);
    }
    expect(isMidiFilePath('C:/Music/song.KAR'), isTrue);
    expect(isMidiFilePath('C:/Music/song.mp3'), isFalse);
  });

  test('module metadata remains distinct from ordinary file tags', () {
    final info = TrackerModuleInfo.fromMap({
      'title': 'Space Journey',
      'format': 'FastTracker 2 XM',
    });
    expect(info.title, 'Space Journey');
    expect(info.format, 'FastTracker 2 XM');
  });
}
