import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

void main() {
  group('what the participant is told', () {
    test('names the pitch they are counting', () {
      expect(
        oddballInstruction(OddballState.running, rareIsHigh: true),
        'Silently count the high tones. Keep still and look at the dot.',
      );
      expect(
        oddballInstruction(OddballState.running, rareIsHigh: false),
        'Silently count the low tones. Keep still and look at the dot.',
      );
    });

    test('settles them before the tones and releases them after', () {
      expect(oddballInstruction(OddballState.preparing, rareIsHigh: true), startsWith('Look at the dot'));
      expect(oddballInstruction(OddballState.finishing, rareIsHigh: true), startsWith('Done'));
    });

    test('says nothing when no run is on', () {
      expect(oddballInstruction(OddballState.idle, rareIsHigh: true), isNull);
    });

    test('never mentions a tone count, which would pull against the counting', () {
      for (final state in OddballState.values) {
        final text = oddballInstruction(state, rareIsHigh: true) ?? '';
        expect(text, isNot(contains(RegExp(r'\d'))), reason: state.name);
      }
    });
  });
}
