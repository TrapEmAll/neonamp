import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/cue_sheet.dart';

void main() {
  test('parses embedded ffmetadata chapters into virtual tracks', () {
    final chapters = parseEmbeddedChapters(''';
[CHAPTER]
TIMEBASE=1/1000
START=0
END=90500
TITLE=Intro\\=Part
[CHAPTER]
TIMEBASE=1/1000
START=90500
END=180000
TITLE=Main\\;Theme
''', r'C:\Music\mix.m4a');
    expect(chapters, hasLength(2));
    expect(chapters.first.trackNumber, 1);
    expect(chapters.first.start, Duration.zero);
    expect(chapters.first.end, const Duration(milliseconds: 90500));
    expect(chapters.first.title, 'Intro=Part');
    expect(chapters.last.title, 'Main;Theme');
  });

  test('rejects invalid chapter ranges and timebases', () {
    expect(
      () => parseEmbeddedChapters('[CHAPTER]\\nTIMEBASE=1/0\\nSTART=0\\nEND=1', 'mix.m4a'),
      throwsFormatException,
    );
    expect(
      () => parseEmbeddedChapters('[CHAPTER]\\nTIMEBASE=1/1000\\nSTART=3\\nEND=2', 'mix.m4a'),
      throwsFormatException,
    );
  });
}
