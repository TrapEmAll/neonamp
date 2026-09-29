import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/audio_trimmer.dart';

void main() {
  test('trim range validation rejects empty, reversed, and oversized ranges', () {
    const duration = Duration(minutes: 3);
    expect(isValidTrimRange(Duration.zero, const Duration(seconds: 1), duration), isTrue);
    expect(isValidTrimRange(Duration.zero, Duration.zero, duration), isFalse);
    expect(isValidTrimRange(const Duration(seconds: 2), const Duration(seconds: 1), duration), isFalse);
    expect(isValidTrimRange(Duration.zero, const Duration(minutes: 4), duration), isFalse);
  });

  test('trim arguments seek and encode a portable WAV snippet', () {
    final args = buildAudioTrimArguments(
      inputPath: 'input.mp3',
      outputPath: 'output.wav',
      start: const Duration(seconds: 12, milliseconds: 250),
      end: const Duration(seconds: 15),
    );
    expect(args, containsAllInOrder([
      '-ss',
      '12.250',
      '-i',
      'input.mp3',
      '-t',
      '2.750',
      '-map',
      '0:a:0',
      '-c:a',
      'pcm_s16le',
      '-f',
      'wav',
      'output.wav',
    ]));
  });
}
