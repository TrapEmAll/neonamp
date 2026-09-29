import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/convolution.dart';

void main() {
  test('accepts common impulse response formats', () {
    expect(isSupportedImpulseResponsePath('room.wav'), isTrue);
    expect(isSupportedImpulseResponsePath('headphone.IR.FLAC'), isTrue);
    expect(isSupportedImpulseResponsePath('profile.mp3'), isFalse);
  });

  test('builds convolution-only filter graph', () {
    expect(buildConvolutionFilter(), '[0:a:0][1:a:0]afir=dry=1:wet=1[out]');
  });

  test('chains equalization after convolution', () {
    expect(
      buildConvolutionFilter(equalizerFilter: 'equalizer=f=1000:t=q:w=1:g=3'),
      '[0:a:0][1:a:0]afir=dry=1:wet=1[conv];[conv]equalizer=f=1000:t=q:w=1:g=3[out]',
    );
  });
}
