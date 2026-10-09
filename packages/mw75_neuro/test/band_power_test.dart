import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

const rate = 496.5; // the lab headset's measured rate

/// [seconds] of samples where each EEG channel follows [signal](channel, t).
List<Mw75Sample> samples(double seconds, double Function(int channel, double t) signal) => [
  for (var i = 0; i < seconds * rate; i++)
    Mw75Sample(
      [for (var c = 0; c < 12; c++) signal(c, i / rate), 2000, 1900, i.toDouble(), 0],
      i / rate,
      status: SampleStatus.measured,
    ),
];

double sine(double hz, double t, {double amplitude = 20}) => amplitude * math.sin(2 * math.pi * hz * t);

void main() {
  BandPowers powersFor(double Function(int, double) signal, {Iterable<int>? channels}) {
    final e = BandPowerEstimator()..addAll(samples(3, signal));
    return e.compute(sampleRate: rate, channels: channels ?? List.generate(12, (i) => i))!;
  }

  test('a pure tone lands in its band', () {
    for (final (hz, band) in [(2.0, EegBand.delta), (6.0, EegBand.theta), (10.0, EegBand.alpha), (20.0, EegBand.beta), (45.0, EegBand.gamma)]) {
      final p = powersFor((c, t) => sine(hz, t));
      expect(p.relative[band], greaterThan(0.9), reason: '$hz Hz should be ${band.label}: ${p.relative}');
    }
  });

  test('measures the power of a sine (A²/2)', () {
    final p = powersFor((c, t) => sine(10, t, amplitude: 20));
    final bandPower = p.density[EegBand.alpha]! * (EegBand.alpha.high - EegBand.alpha.low);
    expect(bandPower, closeTo(20 * 20 / 2, 20)); // 200 µV² within 10%
  });

  test('a large drifting DC offset does not leak into delta', () {
    // Off-head MW75 channels sit near -160000 µV and drift.
    final p = powersFor((c, t) => -160000 + 800 * t + sine(10, t));
    expect(p.relative[EegBand.alpha], greaterThan(0.8));
  });

  test('averages only the selected channels', () {
    double signal(int c, double t) => c < 6 ? sine(10, t) : sine(20, t);
    expect(powersFor(signal, channels: [0]).relative[EegBand.alpha], greaterThan(0.9));
    expect(powersFor(signal, channels: [6]).relative[EegBand.beta], greaterThan(0.9));
    expect(powersFor(signal, channels: [0, 6]).channelsUsed, 2);
  });

  test('waits for ~2 s of data', () {
    final e = BandPowerEstimator()..addAll(samples(1, (c, t) => sine(10, t)));
    expect(e.compute(sampleRate: rate, channels: [0]), isNull);
  });
}
