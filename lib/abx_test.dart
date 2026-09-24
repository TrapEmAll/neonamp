import 'dart:math';

class AbxRound {
  AbxRound({required this.a, required this.b, required this.x});

  final int a;
  final int b;
  final int x;

  bool get xIsA => x == a;
}

class AbxSession {
  AbxSession({
    required this.roundCount,
    Random? random,
  }) : _random = random ?? Random() {
    if (roundCount < 1) throw ArgumentError.value(roundCount, 'roundCount');
    _rounds = [
      for (var index = 0; index < roundCount; index++)
        AbxRound(a: 0, b: 1, x: _random.nextBool() ? 0 : 1),
    ];
  }

  final int roundCount;
  final Random _random;
  late final List<AbxRound> _rounds;
  var _currentRound = 0;
  var _correct = 0;
  var _answered = false;

  int get currentRound => _currentRound;
  int get correctAnswers => _correct;
  int get answeredRounds => _currentRound;
  bool get isComplete => _currentRound >= roundCount;
  double get score => _currentRound == 0 ? 0 : _correct / _currentRound;
  AbxRound get current {
    if (isComplete) throw StateError('The ABX session is complete.');
    return _rounds[_currentRound];
  }

  bool submit({required bool xIsA}) {
    if (isComplete) throw StateError('The ABX session is complete.');
    if (_answered) throw StateError('This round has already been answered.');
    final correct = current.xIsA == xIsA;
    if (correct) _correct++;
    _currentRound++;
    _answered = false;
    return correct;
  }

  void reset() {
    _currentRound = 0;
    _correct = 0;
    _answered = false;
    for (var index = 0; index < _rounds.length; index++) {
      _rounds[index] = AbxRound(
        a: 0,
        b: 1,
        x: _random.nextBool() ? 0 : 1,
      );
    }
  }
}
