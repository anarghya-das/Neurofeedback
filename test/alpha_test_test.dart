import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

import 'support/system_fonts.dart';

const _rate = 496.5;

/// [seconds] of 12-channel EEG: white noise plus a 10 Hz rhythm of
/// [alphaAmplitude] µV on every channel, on top of a 20 mV offset.
List<Mw75Sample> _eeg(
  double seconds, {
  required double alphaAmplitude,
  required double t0,
  required math.Random random,
  int loseEvery = 0,
  double noise = 5,
}) {
  double gauss() => math.sqrt(-2 * math.log(1 - random.nextDouble())) * math.cos(2 * math.pi * random.nextDouble());
  final n = (seconds * _rate).round();
  return [
    for (var i = 0; i < n; i++)
      Mw75Sample(
        [
          for (var c = 0; c < 12; c++)
            20000 + alphaAmplitude * math.sin(2 * math.pi * 10 * (t0 + i / _rate) + c) + noise * gauss(),
          0,
          0,
          i.toDouble(),
          0,
        ],
        t0 + i / _rate,
        status: loseEvery > 0 && i % loseEvery == 0 ? SampleStatus.interpolated : SampleStatus.measured,
      ),
  ];
}

/// Six eyes-open and six eyes-closed blocks, analysed the way a run is.
/// [closedNoise] stands in for muscle tension with the eyes closed: broadband
/// power that raises alpha power without being alpha.
List<AlphaBlock> _blocks({
  required double openAlpha,
  required double closedAlpha,
  int seed = 1,
  double closedNoise = 5,
}) {
  final random = math.Random(seed);
  final blocks = <AlphaBlock>[];
  for (var b = 0; b < 12; b++) {
    final closed = b.isOdd;
    final block = AlphaBlock(eyesClosed: closed, cue: b * 20.0, bins: AlphaWindowAnalyzer.binsFor(_rate));
    final analyzer = AlphaWindowAnalyzer();
    for (final w in analyzer.add(
      _eeg(
        16,
        alphaAmplitude: closed ? closedAlpha : openAlpha,
        t0: b * 20.0 + 4,
        random: random,
        noise: closed ? closedNoise : 5,
      ),
      sampleRate: _rate,
    )) {
      block.add(w);
    }
    blocks.add(block);
  }
  return blocks;
}

void main() {
  group('AlphaWindowAnalyzer', () {
    test('measures the power of a 10 Hz rhythm', () {
      final windows = AlphaWindowAnalyzer().add(
        _eeg(30, alphaAmplitude: 10, t0: 0, random: math.Random(2)),
        sampleRate: _rate,
      );
      expect(windows, hasLength(greaterThan(50)));
      // A sine of amplitude A carries A²/2 = 50 µV²; noise adds about 0.5 on
      // average. In a single window, noise at the same frequency can add to or
      // cancel the sine by several µV², so compare the mean.
      final mean = windows.fold(0.0, (s, w) => s + w.alpha[0]) / windows.length;
      expect(mean, closeTo(50.5, 3));
    });

    test('emits a window every 256 samples once 512 have arrived', () {
      final windows = AlphaWindowAnalyzer().add(
        _eeg(2, alphaAmplitude: 0, t0: 0, random: math.Random(2)),
        sampleRate: _rate,
      );
      expect(windows, hasLength((2 * _rate).round() ~/ 256 - 1));
    });

    test('skips windows that are mostly interpolated or span a gap', () {
      final random = math.Random(3);
      final analyzer = AlphaWindowAnalyzer();
      expect(
        analyzer.add(_eeg(3, alphaAmplitude: 10, t0: 0, random: random, loseEvery: 1), sampleRate: _rate),
        isEmpty,
      );
      analyzer.clear();
      final before = _eeg(1.5, alphaAmplitude: 10, t0: 0, random: random);
      final after = _eeg(1.5, alphaAmplitude: 10, t0: 1.8, random: random);
      final windows = [...analyzer.add(before, sampleRate: _rate), ...analyzer.add(after, sampleRate: _rate)];
      for (final w in windows) {
        expect(w.start >= 1.8 || w.end <= 1.5, isTrue, reason: 'window ${w.start}–${w.end} spans the gap');
      }
    });
  });

  group('AlphaSummary', () {
    test("tells alpha apart from a broadband rise by alpha's share", () {
      final real = AlphaSummary.compute(_blocks(openAlpha: 3, closedAlpha: 10), [0, 1, 2], binHz: _rate / 512);
      // Alpha already makes up most of this synthetic 2–30 Hz band (no 1/f
      // background), so its share can only rise so far.
      expect(real.shareRatio, greaterThan(1.2));
      expect(real.shareP, lessThan(0.01));

      // Eyes closed adds only broadband power: alpha power rises, its share does not.
      final muscle = AlphaSummary.compute(_blocks(openAlpha: 3, closedAlpha: 3, closedNoise: 12), [
        0,
        1,
        2,
      ], binHz: _rate / 512);
      expect(muscle.ratio, greaterThan(1.3));
      expect(muscle.p, lessThan(0.01));
      expect(muscle.shareRatio, lessThan(1));
      expect(muscle.shareP == null || muscle.shareP! >= 0.05 || muscle.shareRatio! < 1, isTrue);
    });

    test('finds the eyes-closed rise, its size and its frequency', () {
      final s = AlphaSummary.compute(_blocks(openAlpha: 3, closedAlpha: 10), [0, 1, 2], binHz: _rate / 512);
      expect(s.openBlocks, 6);
      expect(s.closedBlocks, 6);
      expect(s.ratio, greaterThan(5));
      expect(s.p, closeTo(2 / 924, 1e-9)); // every arrangement checked; this is the smallest possible
      expect(s.peakHz, closeTo(10, 1));
      expect(s.closedSpectrum!.length, s.openSpectrum!.length);
    });

    test('rarely finds a difference that is not there', () {
      var positives = 0;
      for (var seed = 1; seed <= 10; seed++) {
        final s = AlphaSummary.compute(_blocks(openAlpha: 4, closedAlpha: 4, seed: seed), [0], binHz: _rate / 512);
        if (s.p! < 0.05) positives++;
      }
      expect(positives, lessThanOrEqualTo(2));
    });

    test('waits for enough blocks before testing', () {
      final blocks = _blocks(openAlpha: 3, closedAlpha: 10).take(4).toList();
      final s = AlphaSummary.compute(blocks, [0], binHz: _rate / 512);
      expect(s.ratio, isNotNull);
      expect(s.p, isNull);
    });
  });

  group('saved runs', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mw75_runs'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('an alpha run survives a save and load', () async {
      final store = TestRunStore(dir);
      final run = AlphaRun(started: DateTime(2026, 10, 9, 3), settings: const AlphaSettings(), binHz: _rate / 512);
      run.blocks.addAll(_blocks(openAlpha: 3, closedAlpha: 10));
      run.timeline.add((12.5, Float64List.fromList(List.filled(12, 4.25))));
      final recorder = await store.begin(AlphaRun.kind, run.started);
      recorder.addSamples(_eeg(0.1, alphaAmplitude: 0, t0: 0, random: math.Random(1)));
      await recorder.finish(run.toJson());

      final saved = await store.load(AlphaRun.kind);
      expect(saved, hasLength(1));
      final loaded = AlphaRun.fromJson(saved.single.$2, folder: saved.single.$1);
      expect(loaded.included, isFalse);
      final before = AlphaSummary.compute(run.blocks, [0, 1], binHz: run.binHz);
      final after = AlphaSummary.compute(loaded.blocks, [0, 1], binHz: loaded.binHz);
      expect(after.ratio, closeTo(before.ratio!, 1e-3));
      expect(after.p, before.p);
      expect(loaded.timeline.single.$2[3], 4.25);

      final csv = File('${saved.single.$1}/eeg.csv').readAsLinesSync();
      expect(csv.first, startsWith('lsl_time,ch1_uV,'));
      expect(csv, hasLength(1 + (0.1 * _rate).round()));
    });

    test('an oddball run survives a save and load', () async {
      final store = TestRunStore(dir);
      final run = OddballRun(started: DateTime(2026, 10, 9, 4), settings: const OddballSettings(rareIsHigh: false))
        ..output = 'MacBook Pro Speakers'
        ..latency = 0.0015
        ..trialsPlayed = 2
        ..rejections[EpochRejection.dropout] = 1;
      run.epochs.add(
        ErpEpoch(
          const StimulusEvent(onset: 101.25, rare: true),
          List.generate(12, (c) => Float64List.fromList(List.generate(ErpEpoch.length, (i) => c + i / 1000))),
          lostFraction: 0.125,
        ),
      );
      final recorder = await store.begin(OddballRun.kind, run.started);
      await recorder.finish(run.toJson());
      // Runs of another kind are not listed.
      expect(await store.load(AlphaRun.kind), isEmpty);

      final (folder, json) = (await store.load(OddballRun.kind)).single;
      final loaded = OddballRun.fromJson(json, folder: folder);
      expect(loaded.settings.rareIsHigh, isFalse);
      expect(loaded.settings.rareHz, 1000);
      expect(loaded.output, 'MacBook Pro Speakers');
      expect(loaded.rejections[EpochRejection.dropout], 1);
      expect(loaded.epochs.single.event.rare, isTrue);
      expect(loaded.epochs.single.channels[5][100], closeTo(5.1, 1e-9));
      expect(jsonDecode(File('$folder/run.json').readAsStringSync())['kind'], 'oddball');
    });
  });

  // MW75_RENDER=/path/to.png flutter test test/alpha_test_test.dart
  testWidgets('lays out the alpha view without overflow', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      final bytes = File(systemFontPath(file)).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
    final session = AlphaSession(headset: Mw75Headset(), store: TestRunStore(Directory('/tmp/none')));
    addTearDown(session.dispose);
    final run = AlphaRun(started: DateTime(2026, 10, 9, 3), settings: const AlphaSettings(), binHz: _rate / 512);
    final blocks = _blocks(openAlpha: 3, closedAlpha: 8);
    for (final b in blocks) {
      b.end = b.cue + 20;
      for (var i = 0; i < b.windows; i++) {
        run.timeline.add((b.windowTimes[i], b.windowAlpha[i]));
      }
    }
    run.blocks.addAll(blocks);
    session.runs.add(run);

    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1120, 820));
    Widget card(String title, Widget child, {bool expand = false}) => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD9DCE3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          if (expand) Expanded(child: child) else child,
        ],
      ),
    );
    final all = List.generate(12, (i) => i);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Container(
              color: const Color(0xFFF7F7F8),
              padding: const EdgeInsets.all(20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 340,
                    child: ListView(children: [card('Eyes-closed alpha', AlphaControls(session: session))]),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          flex: 2,
                          child: card('Alpha over time', AlphaTimeline(session: session, channels: all), expand: true),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          flex: 3,
                          child: card('Spectrum', AlphaSpectrumPanel(session: session, channels: all), expand: true),
                        ),
                        const SizedBox(height: 14),
                        Expanded(
                          flex: 2,
                          child: card(
                            'Each channel',
                            AlphaChannelBars(session: session, selected: 4, onSelected: (_) {}),
                            expand: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Clear'), findsNWidgets(2));
    final renderPath = Platform.environment['MW75_RENDER'];
    if (renderPath == null) return;
    await tester.runAsync(() async {
      final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(renderPath).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
