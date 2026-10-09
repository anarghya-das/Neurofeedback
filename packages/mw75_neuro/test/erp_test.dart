import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// A headset at its real ~496.5 Hz with DC offset, drift and noise on every
/// channel, plus [response] (µV, by seconds after onset) after each tone.
class _SyntheticEeg {
  _SyntheticEeg({int seed = 3}) : _random = math.Random(seed);

  static const rate = 496.5;

  /// Per-sample noise, µV RMS.
  static const noise = 15.0;
  final math.Random _random;
  // Tones in onset order; [_first] is the earliest whose response may not be over.
  final _events = <(double, double Function(double))>[];
  int _first = 0;
  int _index = 0;
  double t0 = 1000;

  void tone(double onset, double Function(double) response) => _events.add((onset, response));

  double _gauss() {
    final u = 1 - _random.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * _random.nextDouble());
  }

  /// The next [seconds] of samples; every [loseEvery]th sample is marked
  /// interpolated.
  List<Mw75Sample> next(double seconds, {int loseEvery = 0}) {
    final out = <Mw75Sample>[];
    final n = (seconds * rate).round();
    for (var k = 0; k < n; k++, _index++) {
      final t = t0 + _index / rate;
      while (_first < _events.length && t - _events[_first].$1 >= 1) {
        _first++;
      }
      var evoked = 0.0;
      for (var e = _first; e < _events.length && _events[e].$1 <= t; e++) {
        evoked += _events[e].$2(t - _events[e].$1);
      }
      final values = [
        for (var c = 0; c < 12; c++) 20000 + 300 * c + 40 * math.sin(0.3 * t + c) + noise * _gauss() + evoked,
        0.0, 0.0, _index.toDouble(), 0.0,
      ];
      final status = loseEvery > 0 && _index % loseEvery == 0 ? SampleStatus.interpolated : SampleStatus.measured;
      out.add(Mw75Sample(values, t, status: status));
    }
    return out;
  }
}

double _gaussianBump(double t, double centre, double width, double amplitude) =>
    amplitude * math.exp(-math.pow((t - centre) / width, 2) / 2);

void main() {
  group('ErpFilter', () {
    double gainAt(double hz) {
      final x = Float64List.fromList([for (var i = 0; i < 5000; i++) math.sin(2 * math.pi * hz * i / 500)]);
      ErpFilter().apply(x);
      var peak = 0.0;
      for (var i = 1500; i < 3500; i++) {
        peak = math.max(peak, x[i].abs());
      }
      return peak;
    }

    test('passes the ERP band and removes drift, line noise and EMG', () {
      expect(gainAt(5), closeTo(1, 0.05));
      expect(gainAt(10), closeTo(1, 0.05));
      expect(gainAt(0.05), lessThan(0.05));
      expect(gainAt(60), lessThan(0.001));
      expect(gainAt(100), lessThan(0.001));
    });

    test('is zero-phase: a peak keeps its latency', () {
      final x = Float64List.fromList([for (var i = 0; i < 1500; i++) _gaussianBump(i / 500, 1.5, 0.03, 10)]);
      ErpFilter().apply(x);
      var at = 0;
      for (var i = 0; i < x.length; i++) {
        if (x[i] > x[at]) at = i;
      }
      expect(at / 500, closeTo(1.5, 0.004));
    });
  });

  group('EpochExtractor', () {
    test('recovers a response buried in noise at the right latency', () {
      final eeg = _SyntheticEeg();
      final extractor = EpochExtractor();
      final epochs = <ErpEpoch>[];
      var onset = eeg.t0 + 2;
      for (var i = 0; i < 60; i++) {
        eeg.tone(onset, (dt) => _gaussianBump(dt, 0.3, 0.05, 8));
        extractor.addEvent(StimulusEvent(onset: onset, rare: true));
        onset += 1.1;
      }
      for (var i = 0; i < 80; i++) {
        for (final o in extractor.addSamples(eeg.next(1))) {
          expect(o.rejection, isNull);
          epochs.add(o.epoch!);
        }
      }
      expect(epochs, hasLength(60));
      final summary = ErpSummary.compute(epochs, [0]);
      final peak = List.generate(ErpEpoch.length, (i) => i).reduce((a, b) => summary.rareMean[a] > summary.rareMean[b] ? a : b);
      expect(ErpEpoch.timeAt(peak), closeTo(0.3, 0.012));
      expect(summary.rareMean[peak], closeTo(8, 2.5));
      // Baseline-corrected: flat before onset despite the 20 mV offsets.
      for (var i = 0; i < ErpEpoch.baselineLength; i++) {
        expect(summary.rareMean[i].abs(), lessThan(2));
      }
    });

    test('waits for the padding after a tone before cutting its epoch', () {
      final eeg = _SyntheticEeg();
      final extractor = EpochExtractor();
      extractor.addEvent(StimulusEvent(onset: eeg.t0 + 2, rare: false));
      expect(extractor.addSamples(eeg.next(3.7)), isEmpty);
      expect(extractor.addSamples(eeg.next(0.2)), hasLength(1));
    });

    test('rejects tones without EEG before them, and epochs that are mostly interpolated', () {
      final eeg = _SyntheticEeg();
      final extractor = EpochExtractor();
      extractor.addEvent(StimulusEvent(onset: eeg.t0 + 0.5, rare: false));
      final early = extractor.addSamples(eeg.next(3));
      expect(early.single.rejection, EpochRejection.noData);

      extractor.addEvent(StimulusEvent(onset: eeg.t0 + 5, rare: false));
      final lossy = extractor.addSamples(eeg.next(5, loseEvery: 1));
      expect(lossy.single.rejection, EpochRejection.lostData);
    });

    test('rejects epochs spanning a gap in the data', () {
      final eeg = _SyntheticEeg();
      final extractor = EpochExtractor();
      extractor.addEvent(StimulusEvent(onset: eeg.t0 + 2, rare: false));
      final before = eeg.next(2.1);
      eeg.next(0.3); // never delivered
      final outcomes = [...extractor.addSamples(before), ...extractor.addSamples(eeg.next(3))];
      expect(outcomes.single.rejection, EpochRejection.dropout);
    });
  });

  group('ErpSummary', () {
    List<ErpEpoch> run({required double rareP3, required double allN1, int seed = 5}) {
      final eeg = _SyntheticEeg(seed: seed);
      final extractor = EpochExtractor();
      final epochs = <ErpEpoch>[];
      final sequence = oddballSequence(trials: 150, rareProbability: 0.2, random: math.Random(seed));
      var onset = eeg.t0 + 2;
      for (final rare in sequence) {
        eeg.tone(onset, (dt) => _gaussianBump(dt, 0.11, 0.025, allN1) + (rare ? _gaussianBump(dt, 0.35, 0.08, rareP3) : 0));
        extractor.addEvent(StimulusEvent(onset: onset, rare: rare));
        onset += 1.15;
      }
      for (var i = 0; i < 190; i++) {
        for (final o in extractor.addSamples(eeg.next(1))) {
          if (o.epoch != null) epochs.add(o.epoch!);
        }
      }
      return epochs;
    }

    test('finds a P300 and an N1 that are there', () {
      final s = ErpSummary.compute(run(rareP3: 6, allN1: -4), [0, 1, 2]);
      expect(s.rareCount, 30);
      expect(s.standardCount, 120);
      expect(s.oddball!.p, lessThan(0.01));
      expect(s.oddball!.effect, greaterThan(2));
      expect(s.response!.p, lessThan(0.01));
      expect(s.response!.effect, lessThan(0));
    });

    test('does not find effects in noise alone', () {
      var falsePositives = 0;
      for (var seed = 10; seed < 20; seed++) {
        final s = ErpSummary.compute(run(rareP3: 0, allN1: 0, seed: seed), [0]);
        if (s.oddball!.p < 0.05) falsePositives++;
        if (s.response!.p < 0.05) falsePositives++;
      }
      // 20 tests at α = 0.05: one or two by chance, rarely more.
      expect(falsePositives, lessThanOrEqualTo(4));
    });

    test('leaves out epochs over the amplitude threshold', () {
      final epochs = run(rareP3: 0, allN1: 0);
      final spike = Float64List(ErpEpoch.length)..[100] = 500;
      final bad = ErpEpoch(const StimulusEvent(onset: 0, rare: false), List.filled(12, spike), lostFraction: 0);
      final kept = ErpSummary.compute([...epochs, bad], [0], rejectAbove: 100);
      expect(kept.artifactCount, 1);
      expect(ErpSummary.compute([...epochs, bad], [0]).artifactCount, 0);
    });
  });

  group('oddballSequence', () {
    test('has the requested rare count, a standard lead, and no rare tones close together', () {
      for (var seed = 0; seed < 20; seed++) {
        final seq = oddballSequence(trials: 200, rareProbability: 0.2, random: math.Random(seed));
        expect(seq, hasLength(200));
        expect(seq.where((r) => r), hasLength(40));
        expect(seq.take(5).any((r) => r), isFalse);
        var sinceRare = 99;
        for (final rare in seq) {
          if (rare) {
            expect(sinceRare, greaterThanOrEqualTo(2));
            sinceRare = 0;
          } else {
            sinceRare++;
          }
        }
      }
    });

    test('caps the rare count when the constraints cannot fit', () {
      final seq = oddballSequence(trials: 12, rareProbability: 0.5);
      expect(seq, hasLength(12));
      expect(seq.where((r) => r), hasLength(3));
    });
  });
}
