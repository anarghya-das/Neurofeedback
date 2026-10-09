import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

List<int> h(String hex) => [for (final b in hex.split(' ')) int.parse(b, radix: 16)];

Mw75Packet decoded(int counter, double raw, double time) => Mw75PacketParser().add(
  Mw75PacketParser.encode(
    counter: counter,
    ref: 2000,
    drl: 1900,
    rawChannels: List.filled(Mw75Protocol.eegChannelCount, raw),
  ),
  time,
).single;

void main() {
  group('GAIA', () {
    test('splits merged replies captured from a real MW75', () {
      // One RFCOMM callback carried the firmware-version reply and the
      // get_current_state reply back to back.
      final parser = GaiaFrameParser();
      final frames = parser.add(
        h('FF 03 00 08 00 1D 01 05 32 2E 30 2E 30 2E 37 34 FF 03 00 02 09 9A 03 79 F1 00'),
      );
      expect(frames, hasLength(2));
      expect(frames[0].answers(GaiaCommand.getFirmwareVersion), isTrue);
      expect(String.fromCharCodes(frames[0].payload), '2.0.0.74');
      expect(frames[1].acknowledged, isTrue);
      expect(frames[1].value, 0);
    });

    test('reassembles a reply split across callbacks and matches by command', () {
      final parser = GaiaFrameParser();
      expect(parser.add(h('FF 03 00 02 09 9A')), isEmpty);
      final frames = parser.add(h('03 49 F1 01'));
      expect(frames.single.answers(GaiaCommand.getEegMode), isTrue);
      expect(frames.single.answers(GaiaCommand.getBatteryLevel), isFalse);
      expect(frames.single.value, 1);
    });

    test('does not mistake the battery notification for the battery reply', () {
      // 0x03F1 is pushed unprompted; the real reply is 0x0314.
      final frames = GaiaFrameParser().add(h('FF 03 00 01 09 9A 03 F1 4A FF 03 00 02 09 9A 03 14 F1 4A'));
      expect(frames.map((f) => f.answers(GaiaCommand.getBatteryLevel)), [false, true]);
      expect(frames[1].value, 74);
    });

    test('decodes the headset\'s per-cup contact level', () {
      // Frames captured from the lab headset in raw mode.
      final frames = GaiaFrameParser().add(h('FF 03 00 02 09 9A 03 E1 05 05 FF 03 00 02 09 9A 03 E1 02 04'));
      expect(frames.map((f) => f.cupContact), [(5, 5), (2, 4)]);
      // Ordinary replies are not contact levels.
      expect(GaiaFrameParser().add(h('FF 03 00 02 09 9A 03 14 F1 4A')).single.cupContact, isNull);
    });

    test('update_clock encodes Unix seconds and UTC offset little-endian', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1791425488 * 1000);
      final bytes = GaiaCommand.updateClock(now).bytes;
      expect(bytes.sublist(0, 8), h('FF 04 00 06 09 9A 03 31'));
      expect(bytes.sublist(8, 12), h('D0 FB C6 6A'));
      final offset = ByteData.sublistView(Uint8List.fromList(bytes)).getInt16(12, Endian.little);
      expect(offset, now.timeZoneOffset.inMinutes);
    });
  });

  group('Mw75StreamProcessor', () {
    test('fills counter gaps by interpolation and counts the loss', () {
      final p = Mw75StreamProcessor();
      expect(p.add(decoded(10, 0, 1.000)), hasLength(1));
      final out = p.add(decoded(13, rawFor(30), 1.006));
      expect(out, hasLength(3));
      expect(out.map((s) => s.interpolated), [true, true, false]);
      expect(out[0].values[0], closeTo(10, 1e-3));
      expect(out[1].values[0], closeTo(20, 1e-3));
      expect(out.map((s) => s.values[14]), [1, 2, 3]);
      // The sampleStatus channel marks the filled-in samples.
      expect(out.map((s) => s.values[15]), [SampleStatus.interpolated, SampleStatus.interpolated, SampleStatus.measured]);
      expect(p.lost, 2);
      expect(p.lossRatio, closeTo(2 / 4, 1e-9));
    });

    test('flags the first sample after more than 0.5 s without data', () {
      final p = Mw75StreamProcessor();
      p.add(decoded(10, 0, 1.0));
      final out = p.add(decoded(15, 0, 1.7));
      // The counter says 4 were lost, but after 0.7 s of silence it may have
      // wrapped, so the measured sample after the gap carries status 2.
      expect(out.map((s) => s.values[15]), [1, 1, 1, 1, SampleStatus.afterLongDropout]);
      expect(p.longDropouts, 1);
      expect(p.add(decoded(16, 0, 1.702)).single.values[15], SampleStatus.measured);
    });

    test('leaves gaps alone when interpolation is off', () {
      final p = Mw75StreamProcessor(interpolate: false);
      p.add(decoded(255, 0, 1.0));
      final out = p.add(decoded(2, 0, 1.006));
      expect(out.single.values[14], 3);
      expect(out.single.status, SampleStatus.measured);
    });

    test('drops duplicate counters', () {
      final p = Mw75StreamProcessor();
      p.add(decoded(5, 0, 1.0));
      expect(p.add(decoded(5, 0, 1.002)), isEmpty);
      expect(p.duplicates, 1);
    });

    test('timestamps stay evenly spaced and converge on the transport delay', () {
      final p = Mw75StreamProcessor();
      final times = <double>[];
      // Packets arrive in bursts of 10, each burst 20 ms after its last sample.
      const count = 600;
      for (var i = 0; i < count; i++) {
        final burstEnd = (i ~/ 10) * 10 + 9;
        final arrival = 10.0 + burstEnd * 0.002 + 0.02;
        times.addAll(p.add(decoded(i, 0, arrival)).map((s) => s.time));
      }
      for (var i = 1; i < times.length; i++) {
        expect(times[i] - times[i - 1], inInclusiveRange(0.0019 - 1e-12, 0.0021 + 1e-12));
      }
      for (var i = count - 50; i < count; i++) {
        // Within the 500 ppm drift allowance accumulated between bursts.
        expect(times[i], closeTo(10.0 + i * 0.002 + 0.02, 2e-5));
      }
    });

    test('timestamps follow a headset that runs slower than 500 Hz, without drift', () {
      // The lab headset delivers ~496.5 samples per real second. Simulate that with
      // 15% packet loss and delivery in 100 ms bursts arriving 20-60 ms late.
      const trueRate = 496.5;
      const seconds = 60.0;
      final rng = math.Random(7);
      final p = Mw75StreamProcessor();
      final out = <Mw75Sample>[];
      var next = 0;
      for (var burst = 0.1; burst <= seconds; burst += 0.1) {
        final arrival = 100.0 + burst + 0.02 + rng.nextDouble() * 0.04;
        while (next / trueRate <= burst) {
          if (rng.nextDouble() > 0.15) out.addAll(p.add(decoded(next & 0xFF, 0, arrival)));
          next++;
        }
      }
      expect(p.effectiveRate, closeTo(trueRate, 0.3));
      for (var i = 1; i < out.length; i++) {
        expect(out[i].time, greaterThan(out[i - 1].time));
      }
      // Error against the true sampling time, once the fit has 30 s of history.
      double errorAt(double t) {
        final s = out.firstWhere((s) => s.values[14] >= t * trueRate);
        return s.time - (100.0 + s.values[14] / trueRate);
      }
      final e40 = errorAt(40), e58 = errorAt(58);
      expect(e40, inInclusiveRange(0.0, 0.04)); // a fixed transport delay, not drift
      expect((e58 - e40).abs(), lessThan(0.005));
    });

    test('rate estimate is not fooled by the link waking up or by stalls', () {
      // Reproduces a real session: for ~9 s the link trickles packets that are up
      // to a second old, then delivers the backlog, then runs normally with a 1 s
      // stall every 10 s. Least squares read this as ~515 Hz.
      const trueRate = 496.5;
      final rng = math.Random(11);
      final p = Mw75StreamProcessor();
      final out = <Mw75Sample>[];
      var next = 0;
      void deliver(double arrival, double sampledUpTo, double keep) {
        while (next / trueRate <= sampledUpTo) {
          if (rng.nextDouble() < keep) out.addAll(p.add(decoded(next & 0xFF, 0, 100 + arrival)));
          next++;
        }
      }

      final rates = <double, double?>{};
      for (var step = 1; step <= 600; step++) {
        final t = step / 10;
        if (t < 9) {
          if (step % 5 == 0) deliver(t, t - 0.8, 0.05);
        } else if (t % 10 >= 1.0) {
          deliver(t + 0.02 + rng.nextDouble() * 0.04, t, 0.85);
        }
        if (step % 50 == 0) rates[t] = p.effectiveRate;
      }
      for (final r in rates.values.whereType<double>()) {
        expect(r, closeTo(trueRate, 1.0), reason: 'every reported rate must be plausible: $rates');
      }
      expect(p.effectiveRate, closeTo(trueRate, 0.5));
      for (var i = 1; i < out.length; i++) {
        expect(out[i].time, greaterThan(out[i - 1].time));
      }
    });

    test('loss window reports only the recent stretch', () {
      final w = LossWindow(length: 3);
      expect(w.ratio, isNull);
      w.add(100, 900); // a terrible start…
      w.add(500, 900);
      expect(w.ratio, 0); // …is not counted against the last stretch
      w.add(900, 1000);
      expect(w.ratio, closeTo(100 / 900, 1e-9));
      w.add(1300, 1100); // oldest snapshot drops out of the window
      expect(w.ratio, closeTo(200 / 1000, 1e-9));
      w.clear();
      expect(w.ratio, isNull);
    });

    test('output follows Research Kit layout', () {
      final s = Mw75StreamProcessor().add(decoded(0, rawFor(12.5), 1.0)).single;
      expect(s.values, hasLength(16));
      expect(s.values[0], closeTo(12.5, 1e-3));
      expect(s.values[12], 2000);
      expect(s.values[13], 1900);
      expect(s.values[15], 0);
    });
  });
}

double rawFor(double uv) => uv / Mw75Protocol.rawToMicrovolts;
