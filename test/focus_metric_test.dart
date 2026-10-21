import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

const _rate = 496.5;

/// [seconds] of 12-channel EEG with a 10 Hz rhythm of [alpha] µV and a 6 Hz
/// rhythm of [theta] µV on every channel, plus noise and a 20 mV offset.
List<Mw75Sample> _eeg(
  double seconds, {
  required double alpha,
  required double theta,
  required math.Random random,
  double t0 = 0,
  double gain = 1,
}) {
  double gauss() => math.sqrt(-2 * math.log(1 - random.nextDouble())) * math.cos(2 * math.pi * random.nextDouble());
  final n = (seconds * _rate).round();
  return [
    for (var i = 0; i < n; i++)
      () {
        final t = t0 + i / _rate;
        return Mw75Sample(
          [
            for (var c = 0; c < 12; c++)
              20000 +
                  gain *
                      (alpha * math.sin(2 * math.pi * 10 * t + c) +
                          theta * math.sin(2 * math.pi * 6 * t + 2 * c) +
                          4 * gauss()),
            0,
            0,
            i.toDouble(),
            0,
          ],
          t,
          status: SampleStatus.measured,
        );
      }(),
  ];
}

/// A window whose features are drawn around [means] (one value per feature).
FocusWindow _window(List<double> means, math.Random random, {double spread = 0.25}) {
  double gauss() => math.sqrt(-2 * math.log(1 - random.nextDouble())) * math.cos(2 * math.pi * random.nextDouble());
  return FocusWindow(
    start: 0,
    end: 2,
    features: Float64List.fromList([for (final m in means) m + spread * gauss()]),
    muscle: 0.5 + 0.1 * gauss(),
    broadband: 1 + 0.1 * gauss(),
    lostFraction: 0,
  );
}

/// Four focus and four rest blocks of 40 windows. When focused, alpha (every
/// third feature from index 1) is lower by [alphaDrop] on the right cup.
(List<List<FocusWindow>>, List<List<FocusWindow>>) _blocks(double alphaDrop, {int seed = 1}) {
  final random = math.Random(seed);
  final rest = List.filled(36, 1.0);
  final focus = [for (var i = 0; i < 36; i++) i % 3 == 1 && i ~/ 3 >= 6 ? 1.0 - alphaDrop : 1.0];
  return (
    [
      for (var b = 0; b < 4; b++) [for (var w = 0; w < 40; w++) _window(focus, random)],
    ],
    [
      for (var b = 0; b < 4; b++) [for (var w = 0; w < 40; w++) _window(rest, random)],
    ],
  );
}

void main() {
  group('FocusFeatureExtractor', () {
    test('measures each band as a share of 2–30 Hz power, every 256 samples', () {
      final random = math.Random(1);
      final strong = FocusFeatureExtractor().add(_eeg(4, alpha: 20, theta: 2, random: random), sampleRate: _rate);
      final weak = FocusFeatureExtractor().add(_eeg(4, alpha: 2, theta: 2, random: random), sampleRate: _rate);
      expect(strong, hasLength(((4 * _rate).round() - FocusFeatureExtractor.windowSamples) ~/ 256 + 1));
      // Feature 1 is Ch1 alpha. With a strong rhythm alpha is nearly all of the
      // power (share ≈ 1, log ≈ 0); with a weak one about 40% (log ≈ −0.4).
      expect(strong.last.features[1], closeTo(0, 0.05));
      expect(weak.last.features[1], closeTo(-0.4, 0.15));
      // Theta's share falls when alpha takes over the power.
      expect(strong.last.features[0] - weak.last.features[0], lessThan(-1));
      expect(FocusFeatureExtractor.featureName(1), 'Ch1 alpha');
    });

    test('ignores a change in overall amplitude, which shows up in broadband power instead', () {
      final a = FocusFeatureExtractor()
          .add(_eeg(3, alpha: 8, theta: 4, random: math.Random(2)), sampleRate: _rate)
          .last;
      final b = FocusFeatureExtractor()
          .add(_eeg(3, alpha: 8, theta: 4, random: math.Random(2), gain: 10), sampleRate: _rate)
          .last;
      for (var i = 0; i < a.features.length; i++) {
        expect(b.features[i], closeTo(a.features[i], 1e-6));
      }
      expect(b.broadband - a.broadband, closeTo(2, 1e-6));
    });
  });

  group('FocusModel', () {
    test('learns a real difference and scores new windows by it', () {
      final (focus, rest) = _blocks(0.6);
      final model = FocusModel.train(focusBlocks: focus, restBlocks: rest);
      expect(model.cvAuc, greaterThan(0.9));
      expect(model.cvAccuracy, greaterThan(0.8));
      final random = math.Random(9);
      final newFocus = _window([for (var i = 0; i < 36; i++) i % 3 == 1 && i ~/ 3 >= 6 ? 0.4 : 1.0], random);
      final newRest = _window(List.filled(36, 1.0), random);
      expect(model.probability(newFocus.features), greaterThan(0.7));
      expect(model.probability(newRest.features), lessThan(0.3));
      // Less right-cup alpha when focused: the top driver, negative.
      final (name, weight) = model.drivers().first;
      expect(name, 'alpha, right cup');
      expect(weight, lessThan(0));
    });

    test('reports about chance when focus and rest do not differ', () {
      final aucs = [
        for (var seed = 1; seed <= 6; seed++)
          () {
            final (focus, rest) = _blocks(0, seed: seed);
            return FocusModel.train(focusBlocks: focus, restBlocks: rest).cvAuc;
          }(),
      ];
      final mean = aucs.reduce((a, b) => a + b) / aucs.length;
      expect(mean, closeTo(0.5, 0.12));
      expect(aucs.where((a) => a >= FocusSession.minUsefulAuc).length, lessThanOrEqualTo(1));
    });

    test('survives a save and load', () {
      final (focus, rest) = _blocks(0.6);
      final model = FocusModel.train(focusBlocks: focus, restBlocks: rest, now: DateTime(2026, 10, 12, 9));
      final loaded = FocusModel.fromJson((jsonDecode(jsonEncode(model.toJson())) as Map).cast<String, Object?>());
      final w = focus.first.first;
      expect(loaded.probability(w.features), closeTo(model.probability(w.features), 1e-12));
      expect(loaded.cvAuc, model.cvAuc);
      expect(loaded.trainedOn, model.trainedOn);
      expect(loaded.created, DateTime(2026, 10, 12, 9));
    });

    test('leaves out artifact windows and blocks without enough clean EEG', () {
      final (focus, rest) = _blocks(0.6);
      final random = math.Random(5);
      // A burst of movement in one rest block, and a nearly empty focus block.
      for (var i = 0; i < 8; i++) {
        final w = _window(List.filled(36, 1.0), random);
        rest[1].add(
          FocusWindow(start: 0, end: 2, features: w.features, muscle: w.muscle, broadband: 6, lostFraction: 0),
        );
      }
      focus.add([for (var i = 0; i < 3; i++) _window(List.filled(36, 1.0), random)]);
      final model = FocusModel.train(focusBlocks: focus, restBlocks: rest);
      expect(model.windowsLeftOut, 8 + 3);
      expect(model.blocksLeftOut, 1);
      expect(model.blocksUsed, (4, 4));
      expect(model.cvAuc, greaterThan(0.9));
      expect(model.isClean(rest[1].last), isFalse);
    });

    test('refuses to train on fewer than two usable blocks of each', () {
      final (focus, rest) = _blocks(0.6);
      expect(() => FocusModel.train(focusBlocks: focus.take(1).toList(), restBlocks: rest), throwsA(isA<StateError>()));
    });

    test('rejects a calibration saved by an earlier version', () {
      final (focus, rest) = _blocks(0.6);
      final json = FocusModel.train(focusBlocks: focus, restBlocks: rest).toJson()..['version'] = 1;
      expect(() => FocusModel.fromJson(json), throwsFormatException);
    });

    test('flags windows with unusual muscle power', () {
      final (focus, rest) = _blocks(0.6);
      final model = FocusModel.train(focusBlocks: focus, restBlocks: rest);
      // Calibration muscle is 0.5 ± 0.1 (log10): a tenfold rise is far past the limit.
      expect(model.muscleLimit, inInclusiveRange(0.6, 1.2));
    });
  });
}
