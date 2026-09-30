import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/lrc_lyrics.dart';

void main() {
  test('parses and sorts timestamped LRC lines', () {
    final lines = parseLrcLyrics(
      '[00:02.50]Second\n[00:00.00][00:01.00]First',
    );
    expect(lines.map((line) => line.text), ['First', 'First', 'Second']);
    expect(lines[0].position, Duration.zero);
    expect(lines[2].position, const Duration(seconds: 2, milliseconds: 500));
  });

  test('finds active line by playback position', () {
    final lines = parseLrcLyrics('[00:01.00]One\n[00:03.00]Two');
    expect(activeLrcLine(lines, Duration.zero), -1);
    expect(activeLrcLine(lines, const Duration(seconds: 2)), 0);
    expect(activeLrcLine(lines, const Duration(seconds: 4)), 1);
  });

  test('ignores ordinary lyrics without timestamps', () {
    expect(hasLrcTimestamps('ordinary lyrics'), isFalse);
  });

  test('loads a timestamped sidecar next to an audio file', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-lrc-');
    addTearDown(() => directory.delete(recursive: true));
    final audioPath = '${directory.path}${Platform.pathSeparator}song.mp3';
    await File('${directory.path}${Platform.pathSeparator}song.lrc').writeAsString(
      '[00:01.00]Hello',
    );

    expect(await readSidecarLrc(audioPath), '[00:01.00]Hello');
  });
}
