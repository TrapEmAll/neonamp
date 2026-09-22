import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/main.dart';
import 'package:neonamp/tracker_modules.dart';

void main() {
  test(
    'Android folder scan covers every supported library extension',
    () async {
      final nativeSource = await File(
        'android/app/src/main/kotlin/com/neonamp/neonamp/MainActivity.kt',
      ).readAsString();
      final directoryClassificationStart = nativeSource.indexOf(
        'val isDirectory =',
      );
      final audioClassificationStart = nativeSource.indexOf('val extension =');
      expect(directoryClassificationStart, greaterThanOrEqualTo(0));
      expect(audioClassificationStart, greaterThan(directoryClassificationStart));
      expect(
        nativeSource.indexOf('pending.add(documentId)', directoryClassificationStart),
        greaterThan(directoryClassificationStart),
        reason: 'Recurse through provider directories before classifying files.',
      );
      final nativeSetBody = RegExp(
        r'val audioExtensions = setOf\((.*?)\n\s*\)',
        dotAll: true,
      ).firstMatch(nativeSource)?.group(1);
      expect(nativeSetBody, isNotNull);
      final androidExtensions = RegExp(r'"([^"]+)"')
          .allMatches(nativeSetBody!)
          .map((match) => match.group(1)!)
          .toSet();

      final allExtensions = {
        ...supportedLibraryAudioExtensions,
        ...trackerModuleExtensions,
        ...midiFileExtensions,
      };
      expect(androidExtensions, allExtensions);
    },
  );

  test('tracker module extensions are recognized for library scans', () {
    for (final extension in trackerModuleExtensions) {
      expect(isTrackerModulePath('music.$extension'), isTrue);
      expect(isSupportedLibraryAudioPath('C:/Music/music.$extension'), isTrue);
    }
    expect(isTrackerModulePath('music.MoD'), isTrue);
    expect(isTrackerModulePath('music.mp3'), isFalse);
    expect(isSupportedLibraryAudioPath('C:/Music/video.mp4'), isTrue);
    expect(isSupportedLibraryAudioPath('C:/Music/readme.txt'), isFalse);
  });

  test(
    'individual file picker exposes the shared multi-format library set',
    () async {
      final source = await File('lib/main.dart').readAsString();
      expect(source, contains('...supportedLibraryAudioExtensions'));
      expect(source, contains('...trackerModuleExtensions'));
      expect(source, contains('...midiFileExtensions'));
    },
  );

  test('MIDI and karaoke MIDI files are recognized for library scans', () {
    for (final extension in midiFileExtensions) {
      expect(isMidiFilePath('C:/Music/song.$extension'), isTrue);
      expect(isSupportedLibraryAudioPath('C:/Music/song.$extension'), isTrue);
    }
    expect(isMidiFilePath('C:/Music/song.KAR'), isTrue);
    expect(isMidiFilePath('C:/Music/song.mp3'), isFalse);
  });

  test('crossfade picks the incoming track playback backend', () {
    expect(
      trackRequiresDspPlayback('C:/Music/song.mp3', equalizerEnabled: false),
      isFalse,
    );
    expect(
      trackRequiresDspPlayback('C:/Music/song.mp3', equalizerEnabled: true),
      isTrue,
    );
    expect(
      trackRequiresDspPlayback('C:/Music/song.mod', equalizerEnabled: false),
      isTrue,
    );
    expect(
      trackRequiresDspPlayback(
        'https://radio.example/stream.mp3',
        equalizerEnabled: true,
      ),
      isFalse,
    );
    expect(
      trackRequiresDspPlayback('C:/Music/song.mid', equalizerEnabled: true),
      isFalse,
    );
  });

  test('DSP crossfade preserves the equalizer enabled state', () async {
    final source = await File('lib/main.dart').readAsString();
    expect(source, isNot(contains('equalizerEnabled: true')));
    expect(source, contains('equalizerEnabled: _equalizerEnabled'));
  });

  test('legacy and container audio use the cross-platform decoder path', () {
    for (final extension in [
      'ape',
      'wma',
      'aif',
      'aiff',
      'aifc',
      'mka',
      'mkv',
      'webm',
    ]) {
      final path = 'C:/Music/track.$extension';
      expect(isCrossPlatformFallbackAudioPath(path), isTrue, reason: path);
      expect(
        trackRequiresDspPlayback(path, equalizerEnabled: false),
        isTrue,
        reason: path,
      );
    }
    expect(
      isCrossPlatformFallbackAudioPath('https://radio.example/live'),
      isFalse,
    );
    expect(isCrossPlatformFallbackAudioPath('track.mp3'), isFalse);
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
