import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

void main() {
  group('where runs are saved', () {
    test('uses HOME where it is set', () {
      expect(runsDirectory({'HOME': '/Users/kim'}), '/Users/kim/Documents/MW75 Tests');
    });

    test('falls back to USERPROFILE, which is what Windows sets', () {
      expect(
        runsDirectory({'USERPROFILE': r'C:\Users\kim'}),
        r'C:\Users\kim/Documents/MW75 Tests',
      );
    });

    test('prefers HOME when a shell sets both', () {
      expect(runsDirectory({'HOME': '/home/kim', 'USERPROFILE': r'C:\Users\kim'}), '/home/kim/Documents/MW75 Tests');
    });

    test('never builds a path out of a missing variable', () {
      // The bug this guards: an unset HOME used to give "null/Documents/…".
      expect(runsDirectory(const {}), isNot(contains('null')));
      expect(runsDirectory(const {}), './Documents/MW75 Tests');
    });
  });
}
