import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/folder_artwork.dart';

void main() {
  test('finds cover artwork next to an audio file', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-art-');
    addTearDown(() => directory.delete(recursive: true));
    final audio = File('${directory.path}${Platform.pathSeparator}track.mp3');
    final cover = File('${directory.path}${Platform.pathSeparator}Cover.JPG');
    await audio.writeAsBytes([1]);
    await cover.writeAsBytes([2, 3, 4]);

    expect(await findFolderArtwork(audio.path), orderedEquals([2, 3, 4]));
  });

  test('ignores oversized and unrelated images', () async {
    final directory = await Directory.systemTemp.createTemp('neonamp-art-');
    addTearDown(() => directory.delete(recursive: true));
    final audio = File('${directory.path}${Platform.pathSeparator}track.mp3');
    await audio.writeAsBytes([1]);
    await File('${directory.path}${Platform.pathSeparator}artist.png').writeAsBytes([2]);
    await File('${directory.path}${Platform.pathSeparator}folder.png').writeAsBytes([3, 4]);

    expect(await findFolderArtwork(audio.path, maxBytes: 1), isNull);
  });
}
