import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/library_maintenance.dart';

void main() {
  test('reports missing and duplicate paths independently', () {
    final report = buildLibraryMaintenanceReport(
      libraryPaths: const ['/music/a.mp3', '/music/a.mp3', '/music/b.flac'],
      existingPaths: const {'/music/a.mp3'},
    );

    expect(report.missingPaths, ['/music/b.flac']);
    expect(report.duplicatePaths, ['/music/a.mp3']);
    expect(report.isClean, isFalse);
  });

  test('removes only repeated path entries and preserves order', () {
    expect(
      removeDuplicateLibraryPaths(const ['a', 'b', 'a', 'c', 'b']),
      ['a', 'b', 'c'],
    );
  });
}
