import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// Records what the session asks of the audio output.
class _FakeTones implements ToneOutput {
  final played = <(double, double)>[];
  final held = <(double, double)>[];
  final volumesSet = <double>[];
  double? macVolume = 0.5;
  bool started = false;

  @override
  Future<List<AudioOutputDevice>> devices() async => const [
    AudioOutputDevice(id: 1, name: 'MW75 Neuro', isDefault: true, bluetooth: true),
  ];
  @override
  Future<ToneOutputInfo> start({int? deviceId}) async {
    started = true;
    return const ToneOutputInfo(device: 'MW75 Neuro', bluetooth: true, sampleRate: 48000, latency: 0);
  }

  @override
  Future<double> play({required double frequency, required double duration, required double amplitude, double? at}) async {
    played.add((frequency, amplitude));
    return at ?? 0;
  }

  @override
  Future<void> stop() async => started = false;
  @override
  Future<void> speak(String? text) async {}
  @override
  Future<void> hold({required double frequency, required double amplitude}) async => held.add((frequency, amplitude));
  @override
  Future<void> release() async {}
  @override
  Future<double?> volume({int? deviceId}) async => macVolume;
  @override
  Future<bool> setVolume(double volume, {int? deviceId}) async {
    volumesSet.add(volume);
    macVolume = volume;
    return true;
  }
}

final _calibration = SoundCalibration(
  device: 'MW75 Neuro',
  date: DateTime(2026, 10, 13, 9),
  volume: 0.5,
  points: const [
    CalibrationPoint(hz: 1000, dbfs: -30, spl: 62),
    CalibrationPoint(hz: 2000, dbfs: -30, spl: 65),
  ],
  levels: const [60, 70],
);

/// [n] epochs, every fifth rare; epoch [bad] spans 400 µV.
List<ErpEpoch> _epochs(int n, {Set<int> bad = const {}}) => [
  for (var k = 0; k < n; k++)
    ErpEpoch(
      StimulusEvent(onset: k.toDouble(), rare: k % 5 == 4),
      List.generate(
        12,
        (_) => Float64List.fromList([for (var i = 0; i < ErpEpoch.length; i++) bad.contains(k) && i == 200 ? 400 : 0]),
      ),
      lostFraction: 0,
    ),
];

void main() {
  group('OddballSettings', () {
    test('reads runs saved before levels, which kept an amplitude', () {
      final old = OddballSettings.fromJson(const {'trials': 100, 'amplitude': 0.3, 'minInterval': 1.0, 'maxInterval': 1.3});
      expect(old.levelDbfs, closeTo(-10.46, 0.01));
      expect(old.levelSpl, const OddballSettings().levelSpl);
      expect(old.trials, 100);
    });

    test('keeps every setting through JSON and copyWith', () {
      final s = const OddballSettings().copyWith(
        rareProbability: 0.1,
        toneSeconds: 0.05,
        levelSpl: 65,
        levelDbfs: -20,
        minInterval: 0.5,
        maxInterval: 0.7,
      );
      final back = OddballSettings.fromJson(s.toJson());
      expect(back.rareProbability, 0.1);
      expect(back.toneSeconds, 0.05);
      expect(back.levelSpl, 65);
      expect(back.levelDbfs, -20);
      expect(back.minInterval, 0.5);
      expect(back.maxInterval, 0.7);
      expect(back.duration, const Duration(seconds: 120));
    });

    test('the rare share options fit the spacing rule', () {
      for (final p in OddballSettings.rareOptions) {
        final sequence = oddballSequence(trials: 200, rareProbability: p);
        expect(sequence.where((r) => r).length, (200 * p).round(), reason: '$p');
      }
    });
  });

  group('OddballRun', () {
    test('keeps the level it played at through JSON', () {
      final run = OddballRun(started: DateTime(2026, 10, 13, 10), settings: const OddballSettings(levelSpl: 75))
        ..standardDbfs = -17
        ..rareDbfs = -20
        ..calibrationDate = DateTime(2026, 10, 13, 9)
        ..volume = 0.5;
      final back = OddballRun.fromJson(run.toJson(), folder: '/tmp/x');
      expect(back.standardDbfs, -17);
      expect(back.rareDbfs, -20);
      expect(back.calibrationDate, DateTime(2026, 10, 13, 9));
      expect(back.volume, 0.5);
      expect(back.levelLabel, '75 dB SPL');
      final uncalibrated = OddballRun(started: DateTime(2026, 10, 13), settings: const OddballSettings(levelDbfs: -12));
      expect(OddballRun.fromJson(uncalibrated.toJson(), folder: '').levelLabel, '−12 dB, uncalibrated');
    });
  });

  group('OddballSession levels', () {
    late _FakeTones tones;
    late SoundCalibrations calibrations;
    late OddballSession session;

    setUp(() async {
      tones = _FakeTones();
      calibrations = SoundCalibrations();
      session = OddballSession(headset: Mw75Headset(), tones: tones, calibrations: calibrations, publishMarkers: false);
      await session.refreshOutputs();
    });
    tearDown(() => session.dispose());

    test('without a calibration, both tones play at the relative level', () {
      session.settings = const OddballSettings(levelDbfs: -15);
      expect(session.calibration, isNull);
      expect(session.levelsFor(session.settings), (standard: -15.0, rare: -15.0));
      expect(session.levelProblem, isNull);
    });

    test('with one, each tone gets the level that reads as the dB SPL asked for', () async {
      await calibrations.save(_calibration);
      session.settings = const OddballSettings(levelSpl: 70);
      expect(session.calibration, isNotNull);
      // Rare is high (2000 Hz) by default.
      expect(session.levelsFor(session.settings), (standard: -22.0, rare: -25.0));
      expect(session.loudestSpl, 92);
      expect(session.levelProblem, isNull);

      await session.preview();
      expect(tones.played.map((p) => p.$1), [1000, 2000]);
      expect(tones.played[0].$2, closeTo(amplitudeForDbfs(-22), 1e-12));
      expect(tones.played[1].$2, closeTo(amplitudeForDbfs(-25), 1e-12));
    });

    test('a level louder than the output reaches is refused', () async {
      await calibrations.save(_calibration);
      session.settings = const OddballSettings(levelSpl: 95);
      expect(session.levelProblem, contains('up to 92 dB SPL'));
    });

    test('a changed Mac volume is flagged and can be put back', () async {
      await calibrations.save(_calibration);
      tones.macVolume = 0.75;
      await session.refreshVolume();
      expect(session.volumeChanged, isTrue);
      expect(session.levelProblem, contains('75%'));
      await session.restoreVolume();
      expect(tones.volumesSet, [0.5]);
      expect(session.volumeChanged, isFalse);
      expect(session.levelProblem, isNull);
    });

    test('a calibration for another output does not apply', () async {
      await calibrations.save(
        SoundCalibration(device: 'MacBook Pro Speakers', date: DateTime(2026), points: _calibration.points),
      );
      expect(session.calibration, isNull);
    });

    test('steady tones for the meter play at the asked level, never above full scale', () async {
      await session.playSteadyTone(1000, -30);
      await session.playSteadyTone(2000, 3);
      expect(tones.held[0].$2, closeTo(amplitudeForDbfs(-30), 1e-12));
      expect(tones.held[1].$2, 1);
      await session.stopSteadyTone();
      expect(tones.started, isFalse);
    });
  });

  group('OddballSession results', () {
    test('counts used and rejected tones of each kind', () {
      final session = OddballSession(headset: Mw75Headset(), tones: _FakeTones(), publishMarkers: false)
        ..rejectAbove = 100;
      addTearDown(session.dispose);
      // 50 epochs (10 rare); epochs 3 (standard) and 9 (rare) are artifacts.
      // 55 tones played, 12 rare: 3 standard and 2 rare gave no epoch.
      session.runs.add(
        OddballRun(started: DateTime(2026, 10, 13), settings: const OddballSettings())
          ..trialsPlayed = 55
          ..raresPlayed = 12
          ..epochs.addAll(_epochs(50, bad: {3, 9}))
          ..rejections[EpochRejection.dropout] = 5,
      );
      final counts = session.trialCounts(session.summary([0]));
      expect((counts.standard.played, counts.standard.used, counts.standard.rejected), (43, 39, 4));
      expect((counts.rare.played, counts.rare.used, counts.rare.rejected), (12, 9, 3));

      // Unticked runs do not count.
      session.setIncluded(session.runs.single, false);
      final none = session.trialCounts(session.summary([0]));
      expect(none.standard.played + none.rare.played, 0);
    });

    test('re-baselines the averages to the chosen window', () {
      final session = OddballSession(headset: Mw75Headset(), tones: _FakeTones(), publishMarkers: false);
      addTearDown(session.dispose);
      // A step of +2 µV from −100 ms on.
      final step = Float64List.fromList([for (var i = 0; i < ErpEpoch.length; i++) ErpEpoch.timeAt(i) >= -0.1 ? 2 : 0]);
      session.runs.add(
        OddballRun(started: DateTime(2026, 10, 13), settings: const OddballSettings())
          ..trialsPlayed = 1
          ..epochs.add(ErpEpoch(const StimulusEvent(onset: 0, rare: false), List.filled(12, step), lostFraction: 0)),
      );
      expect(session.summary([0], tests: false).standardMean.last, 2);
      session.baseline = (-0.1, 0.0);
      final s = session.summary([0], tests: false);
      expect(s.baseline, (-0.1, 0.0));
      expect(s.standardMean.last, closeTo(0, 1e-12));
      expect(s.standardMean.first, closeTo(-2, 1e-12));
    });
  });
}
