import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/visualizer_metrics.dart';

void main() {
  test('peak hold decays but never loses a newer transient', () {
    final hold = SpectrumPeakHold(decay: .5);
    expect(hold.update([.8, .2]), [.8, .2]);
    expect(hold.update([.1, .1]), [.4, .1]);
    expect(hold.update([.9, .05]), [.9, .05]);
  });

  test('visualizer levels ignore invalid samples and clamp output', () {
    expect(visualizerRms([0, .5, -.5, double.nan]), closeTo(.4082, .001));
    expect(visualizerPeak([-.2, 1.5, double.infinity]), 1);
    expect(visualizerPeak(const <double>[]), 0);
  });
}
