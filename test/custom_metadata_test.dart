import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/custom_metadata.dart';

void main() {
  test('parses and serializes arbitrary metadata fields', () {
    final fields = parseCustomMetadata(
      'Producer = Jane Doe\nBPM=128\ninvalid\nKey=Value=with equals',
    );
    expect(fields['Producer'], 'Jane Doe');
    expect(fields['BPM'], '128');
    expect(fields['Key'], 'Value=with equals');
    expect(
      serializeCustomMetadata(fields),
      'Producer=Jane Doe\nBPM=128\nKey=Value=with equals',
    );
  });

  test('matches metadata expressions case-insensitively', () {
    final fields = {'Master Engineer': 'Alex'};
    expect(customMetadataMatches(fields, 'master engineer=alex'), isTrue);
    expect(customMetadataMatches(fields, 'Genre=Jazz'), isFalse);
  });
}
