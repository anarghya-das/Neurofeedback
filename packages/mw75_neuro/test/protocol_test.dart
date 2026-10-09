import 'dart:typed_data';

import 'package:mw75_neuro/mw75_neuro.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List packet(int counter, {double ref = 2000, double drl = 1900, double raw = 0}) =>
    Mw75PacketParser.encode(
      counter: counter,
      ref: ref,
      drl: drl,
      rawChannels: List.filled(Mw75Protocol.eegChannelCount, raw),
    );

/// Raw ADC count that scales to [uv] microvolts.
double rawFor(double uv) => uv / Mw75Protocol.rawToMicrovolts;

void main() {
  group('Mw75PacketParser', () {
    test('decodes a packet split across chunks', () {
      final parser = Mw75PacketParser();
      final bytes = packet(7, raw: 1234);
      expect(parser.add(Uint8List.sublistView(bytes, 0, 20), 1.0), isEmpty);
      final out = parser.add(Uint8List.sublistView(bytes, 20), 2.0);
      expect(out, hasLength(1));
      expect(out.single.counter, 7);
      expect(out.single.ref, 2000);
      expect(out.single.drl, 1900);
      expect(out.single.rawChannels, everyElement(1234));
      expect(out.single.hostTime, 2.0);
    });

    test('resynchronises after garbage and rejects bad checksums', () {
      final parser = Mw75PacketParser();
      final corrupt = packet(2)..[30] ^= 0xFF;
      final stream = BytesBuilder()
        ..add([0x01, 0xAA, 0x02])
        ..add(packet(1))
        ..add(corrupt)
        ..add(packet(3));
      final out = parser.add(stream.toBytes(), 0);
      expect(out.map((p) => p.counter), [1, 3]);
      expect(parser.checksumErrors, 1);
    });
  });

  group('Mw75SignalQualityEstimator', () {
    List<Mw75SignalQuality> feed(
      Mw75SignalQualityEstimator est,
      int count,
      Mw75Packet Function(int i) make,
    ) {
      final out = <Mw75SignalQuality>[];
      for (var i = 0; i < count; i++) {
        final q = est.add(make(i), i / Mw75Protocol.samplingRate);
        if (q != null) out.add(q);
      }
      return out;
    }

    Mw75Packet decoded(Uint8List bytes) => Mw75PacketParser().add(bytes, 0).single;

    test('reports once per second with Research Kit thresholds', () {
      final est = Mw75SignalQualityEstimator();
      // Ch1 swings ±30 µV (60 p2p → best), Ch2 ±120 µV (240 → acceptable),
      // Ch3 ±200 µV (400 → bad); |Ref−DRL| = 100 → best.
      final reports = feed(est, 501, (i) {
        final sign = i.isEven ? 1.0 : -1.0;
        final raws = List.filled(Mw75Protocol.eegChannelCount, 0.0);
        raws[0] = rawFor(30 * sign);
        raws[1] = rawFor(120 * sign);
        raws[2] = rawFor(200 * sign);
        return decoded(
          Mw75PacketParser.encode(counter: i, ref: 2000, drl: 1900, rawChannels: raws),
        );
      });
      expect(reports, hasLength(1));
      final q = reports.single;
      expect(q.ref, ContactQuality.best);
      expect(q.drl, ContactQuality.best);
      expect(q.channels[0], ContactQuality.best);
      expect(q.channels[1], ContactQuality.acceptable);
      expect(q.channels[2], ContactQuality.bad);
      expect(q.channels[3], ContactQuality.best);
      expect(q.toJson()['ch3Quality'], 'bad');
    });

    test('rates Ref/DRL by mean difference', () {
      ContactQuality refFor(double diff) {
        final est = Mw75SignalQualityEstimator();
        return feed(est, 501, (i) => decoded(packet(i, ref: 2000, drl: 2000 - diff))).single.ref;
      }

      expect(refFor(299), ContactQuality.best);
      expect(refFor(599), ContactQuality.good);
      expect(refFor(1000), ContactQuality.acceptable);
    });

    test('marks everything bad when Ref/DRL are too far apart', () {
      final est = Mw75SignalQualityEstimator();
      final q = feed(est, 501, (i) => decoded(packet(i, ref: 3000, drl: 1000))).single;
      expect(q.ref, ContactQuality.bad);
      expect(q.channels, everyElement(ContactQuality.bad));
    });

    test('marks everything bad when Ref is clipped in over a quarter of the window', () {
      final est = Mw75SignalQualityEstimator();
      final q = feed(est, 501, (i) => decoded(packet(i, ref: i % 3 == 0 ? 4095 : 2000))).single;
      expect(q.ref, ContactQuality.bad);
      expect(q.channels, everyElement(ContactQuality.bad));
    });

    test('marks a channel bad when it sits on the ADC rail', () {
      final est = Mw75SignalQualityEstimator();
      final q = feed(est, 501, (i) => decoded(packet(i, raw: 8388607))).single;
      expect(q.ref, ContactQuality.best);
      expect(q.channels, everyElement(ContactQuality.bad));
    });
  });
}
