import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

SoundCalibration _calibration(List<CalibrationPoint> points) =>
    SoundCalibration(device: 'MW75 Neuro', date: DateTime(2026, 10, 13), volume: 0.5, points: points);

void main() {
  group('SoundCalibration', () {
    test('one reading per tone sets every level, 1 dB in for 1 dB out', () {
      final c = _calibration(const [
        CalibrationPoint(hz: 1000, dbfs: -30, spl: 62),
        CalibrationPoint(hz: 2000, dbfs: -30, spl: 65),
      ]);
      expect(c.covers(1000), isTrue);
      expect(c.covers(500), isFalse);
      expect(c.dbfsFor(1000, 70), closeTo(-22, 1e-9));
      expect(c.dbfsFor(2000, 70), closeTo(-25, 1e-9));
      expect(c.dbfsFor(500, 70), isNull);
      expect(c.splFor(1000, -22), closeTo(70, 1e-9));
      expect(c.maxSpl(1000), closeTo(92, 1e-9));
      expect(c.maxSpl(2000), closeTo(95, 1e-9));
    });

    test('interpolates between readings and extends beyond them', () {
      // The output compresses a little at the top: 20 dB more digital level
      // gives 18 dB more sound.
      final c = _calibration(const [
        CalibrationPoint(hz: 1000, dbfs: -40, spl: 50),
        CalibrationPoint(hz: 1000, dbfs: -20, spl: 68),
      ]);
      expect(c.dbfsFor(1000, 59), closeTo(-30, 1e-9));
      expect(c.splFor(1000, -30), closeTo(59, 1e-9));
      // Beyond the readings: slope 1 from the nearest one.
      expect(c.dbfsFor(1000, 40), closeTo(-50, 1e-9));
      expect(c.dbfsFor(1000, 78), closeTo(-10, 1e-9));
      expect(c.maxSpl(1000), closeTo(88, 1e-9));
    });

    test('a new reading near an old one at the same tone replaces it', () {
      var c = _calibration(const [
        CalibrationPoint(hz: 1000, dbfs: -30, spl: 62),
        CalibrationPoint(hz: 2000, dbfs: -30, spl: 65),
      ]);
      c = c.withPoint(const CalibrationPoint(hz: 1000, dbfs: -29.5, spl: 63));
      expect(c.points.where((p) => p.hz == 1000), hasLength(1));
      expect(c.points.where((p) => p.hz == 2000), hasLength(1));
      expect(c.splFor(1000, -29.5), closeTo(63, 1e-9));
      c = c.withPoint(const CalibrationPoint(hz: 1000, dbfs: -10, spl: 82));
      expect(c.points.where((p) => p.hz == 1000), hasLength(2));
      expect(c.withoutPointsAt(1000).covers(1000), isFalse);
    });

    test('ignores a reading that would make louder play quieter', () {
      final c = _calibration(const [
        CalibrationPoint(hz: 1000, dbfs: -30, spl: 62),
        CalibrationPoint(hz: 1000, dbfs: -25, spl: 61),
      ]);
      expect(c.dbfsFor(1000, 70), closeTo(-22, 1e-9));
    });

    test('keeps quick-pick levels sorted and unique', () {
      final c = _calibration(const []).withLevel(70).withLevel(60).withLevel(70).withLevel(80).withoutLevel(80);
      expect(c.levels, [60, 70]);
    });

    test('survives JSON', () {
      final c = _calibration(const [CalibrationPoint(hz: 1000, dbfs: -30, spl: 62.4)]).withLevel(70);
      final back = SoundCalibration.fromJson(c.toJson());
      expect(back.device, 'MW75 Neuro');
      expect(back.date, c.date);
      expect(back.volume, 0.5);
      expect(back.points.single.spl, 62.4);
      expect(back.levels, [70]);
    });
  });

  group('SoundCalibrations', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mw75_sound'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves to and loads from its file, by output', () async {
      final file = File('${dir.path}/sound calibration.json');
      final store = SoundCalibrations(file: file);
      await store.save(_calibration(const [CalibrationPoint(hz: 1000, dbfs: -30, spl: 62)]));
      await store.save(
        SoundCalibration(device: 'MacBook Pro Speakers', date: DateTime(2026, 10, 12)),
      );
      expect(file.existsSync(), isTrue);

      final again = SoundCalibrations(file: file);
      await again.load();
      expect(again['MW75 Neuro']!.points.single.spl, 62);
      expect(again['MacBook Pro Speakers'], isNotNull);
      expect(again[null], isNull);

      await again.remove('MW75 Neuro');
      final third = SoundCalibrations(file: file);
      await third.load();
      expect(third['MW75 Neuro'], isNull);
    });

    test('a missing or unreadable file leaves it empty', () async {
      final file = File('${dir.path}/sound calibration.json');
      await SoundCalibrations(file: file).load();
      file.writeAsStringSync('not json');
      final store = SoundCalibrations(file: file);
      await store.load();
      expect(store['MW75 Neuro'], isNull);
    });
  });

  test('dB conversions and labels', () {
    expect(amplitudeForDbfs(0), 1);
    expect(amplitudeForDbfs(-20), closeTo(0.1, 1e-12));
    expect(dbfsForAmplitude(0.3), closeTo(-10.457, 1e-3));
    expect(formatDb(70), '70');
    expect(formatDb(72.46), '72.5');
    expect(formatDb(-10.457), '−10.5');
  });
}
