import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:neonamp/abx_test.dart';

void main() {
  test('ABX session tracks deterministic answers and score', () {
    final session = AbxSession(roundCount: 4, random: _FixedRandom([true, false, true, false]));
    expect(session.current.xIsA, isTrue);
    expect(session.submit(xIsA: true), isTrue);
    expect(session.submit(xIsA: true), isFalse);
    expect(session.submit(xIsA: true), isTrue);
    expect(session.submit(xIsA: true), isFalse);
    expect(session.isComplete, isTrue);
    expect(session.correctAnswers, 2);
    expect(session.score, .5);
  });
}

class _FixedRandom implements Random {
  _FixedRandom(this.values);
  final List<bool> values;
  var index = 0;

  @override
  bool nextBool() => values[index++];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
