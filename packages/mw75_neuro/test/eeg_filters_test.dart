import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// The lab headset's real rate.
const _rate = 496.5;

/// Peak amplitude of [hz] (plus [offset]) after [settings], measured over the
/// last 2 s of 10 s so start-up has settled.
double _gain(EegFilterSettings settings, double hz, {double offset = 0, double designRate = _rate}) {
  final bank = EegFilterBank(settings, rate: designRate, eegChannels: 1);
  final n = (10 * _rate).round();
  var peak = 0.0;
  for (var i = 0; i < n; i++) {
    final v = [offset + math.sin(2 * math.pi * hz * i / _rate)];
    bank.filter(v);
    if (i > n - 2 * _rate) peak = math.max(peak, v[0].abs());
  }
  return peak;
}

void main() {
  group('EegFilterBank', () {
    const notchOnly = EegFilterSettings(highPass: false);

    test('the notch removes mains and its harmonic and keeps EEG', () {
      expect(_gain(notchOnly, 60), lessThan(0.01));
      expect(_gain(notchOnly, 120), lessThan(0.01));
      expect(_gain(notchOnly, 10), closeTo(1, 0.01));
      expect(_gain(notchOnly, 40), closeTo(1, 0.03));
      expect(_gain(notchOnly.copyWith(mainsHz: 50), 50), lessThan(0.01));
    });

    test('a notch designed for the nominal 500 Hz misses mains on a 496.5 Hz headset', () {
      // Why the bank is designed for the measured rate.
      expect(_gain(notchOnly, 60, designRate: 500), greaterThan(0.2));
    });

    test('updating the rate re-centres the notch without a jump', () {
      final bank = EegFilterBank(notchOnly, rate: 500, eegChannels: 1);
      var before = 0.0, after = 0.0, largestStep = 0.0, previous = 0.0;
      final n = (20 * _rate).round();
      for (var i = 0; i < n; i++) {
        if (i == n ~/ 2) bank.updateRate(_rate);
        final v = [math.sin(2 * math.pi * 60 * i / _rate) + math.sin(2 * math.pi * 7 * i / _rate)];
        bank.filter(v);
        final residual = (v[0] - math.sin(2 * math.pi * 7 * i / _rate)).abs();
        if (i > n ~/ 2 - _rate && i < n ~/ 2) before = math.max(before, residual);
        if (i > n - _rate) after = math.max(after, residual);
        // Around the switch: a normal sample-to-sample change for this signal
        // is up to ~0.3.
        if ((i - n ~/ 2).abs() < 50) largestStep = math.max(largestStep, (v[0] - previous).abs());
        previous = v[0];
      }
      expect(before, greaterThan(0.2));
      expect(after, lessThan(0.02));
      expect(largestStep, lessThan(0.4));
    });

    test('the high-pass removes the electrode offset and keeps EEG', () {
      const highPassOnly = EegFilterSettings(notch: false);
      expect(_gain(highPassOnly, 10, offset: 20000), closeTo(1, 0.01));
    });

    test('the band-pass keeps its band', () {
      const band = EegFilterSettings(highPass: false, notch: false, bandPass: true, bandLow: 1, bandHigh: 40);
      expect(_gain(band, 10), closeTo(1, 0.02));
      expect(_gain(band, 0.2), lessThan(0.06));
      expect(_gain(band, 100), lessThan(0.05));
      expect(_gain(band, 1), closeTo(math.sqrt1_2, 0.03));
      expect(_gain(band, 40), closeTo(math.sqrt1_2, 0.03));
    });

    test('starting on a large offset does not ring', () {
      const notchOnlyBand = EegFilterSettings(highPass: false, bandPass: true, bandLow: 20, bandHigh: 100);
      final bank = EegFilterBank(notchOnly, rate: _rate, eegChannels: 1);
      for (var i = 0; i < 100; i++) {
        final v = [20000.0];
        bank.filter(v);
        expect(v[0], closeTo(20000, 1e-6));
      }
      // A high-pass starts from zero output for a constant input.
      final hp = EegFilterBank(notchOnlyBand, rate: _rate, eegChannels: 1);
      final v = [20000.0];
      hp.filter(v);
      expect(v[0].abs(), lessThan(1e-6));
    });

    test('Ref and DRL only get the high-pass', () {
      final bank = EegFilterBank(const EegFilterSettings(), rate: _rate, eegChannels: 1, extraChannels: 1);
      var refPeak = 0.0;
      final n = (10 * _rate).round();
      for (var i = 0; i < n; i++) {
        final s = math.sin(2 * math.pi * 60 * i / _rate);
        final v = [s, 500 + s];
        bank.filter(v);
        if (i > n - _rate) refPeak = math.max(refPeak, v[1].abs());
      }
      expect(refPeak, closeTo(1, 0.02));
    });
  });

  group('EegFilterSettings', () {
    test('describes what is on', () {
      expect(const EegFilterSettings().describe(), '0.5 Hz high-pass, 60 Hz notch');
      expect(
        const EegFilterSettings(notch: false, bandPass: true, bandLow: 0.5, bandHigh: 30).describe(),
        '0.5 Hz high-pass, 0.5–30 Hz band-pass',
      );
      expect(EegFilterSettings.off.describe(), 'none');
    });
  });

  group('Mw75StreamProcessor with filters', () {
    Mw75Packet packet(int counter, double microvolts, double time) => Mw75PacketParser()
        .add(
          Mw75PacketParser.encode(
            counter: counter,
            ref: 2000,
            drl: 1900,
            rawChannels: List.filled(Mw75Protocol.eegChannelCount, microvolts / Mw75Protocol.rawToMicrovolts),
          ),
          time,
        )
        .single;

    test('keeps the unfiltered values next to the filtered ones', () {
      final p = Mw75StreamProcessor(filters: const EegFilterSettings());
      final out = [for (var i = 0; i < 50; i++) ...p.add(packet(i, 20000, 100 + i / 500))];
      expect(out.last.raw[0], closeTo(20000, 0.01));
      expect(out.last.values[0].abs(), lessThan(20000 * 0.5));
      expect(out.last.values, hasLength(16));
      expect(out.last.values[14], 49); // counter and status pass through untouched
    });

    test('without filters the values are the measured ones', () {
      final p = Mw75StreamProcessor();
      final s = p.add(packet(0, 12.5, 100)).single;
      expect(identical(s.raw, s.values), isTrue);
      expect(s.values[0], closeTo(12.5, 1e-3));
    });
  });

  group('MainsTracker', () {
    test('finds interference that sits off the nominal frequency and centres the notch on it', () {
      // As on the lab headset: mains at 0.1204 cycles per sample, which a
      // 496.2 Hz rate estimate calls 59.74 Hz, not 60.
      const nu = 0.1204, rate = 496.2;
      final tracker = MainsTracker(channels: 2);
      final random = math.Random(1);
      double? found;
      for (var i = 0; i < 6000; i++) {
        final hum = 50 * math.sin(2 * math.pi * nu * i);
        if (tracker.add([hum + random.nextDouble(), 20000 + hum], expected: 60 / rate)) found = tracker.cyclesPerSample;
      }
      expect(found, closeTo(nu, 2e-5));

      double residual(EegFilterBank bank) {
        var peak = 0.0;
        for (var i = 0; i < 6000; i++) {
          final v = [math.sin(2 * math.pi * nu * i)];
          bank.filter(v);
          if (i > 5000) peak = math.max(peak, v[0].abs());
        }
        return peak;
      }

      const notchOnly = EegFilterSettings(highPass: false);
      expect(residual(EegFilterBank(notchOnly, rate: rate, eegChannels: 1)), greaterThan(0.15));
      expect(residual(EegFilterBank(notchOnly, rate: rate, eegChannels: 1)..setNotchCenter(found!)), lessThan(0.01));
    });

    test('reports nothing without clear interference', () {
      final tracker = MainsTracker(channels: 1);
      final random = math.Random(2);
      for (var i = 0; i < 6000; i++) {
        tracker.add([random.nextDouble() - 0.5], expected: 60 / 496.5);
      }
      expect(tracker.cyclesPerSample, isNull);
    });
  });
}
