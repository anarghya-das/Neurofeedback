import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

class _SilentTones implements ToneOutput {
  @override
  Future<List<AudioOutputDevice>> devices() async => const [];
  @override
  Future<ToneOutputInfo> start({int? deviceId}) async =>
      const ToneOutputInfo(device: '', bluetooth: false, sampleRate: 48000, latency: 0);
  @override
  Future<double> play({required double frequency, required double duration, required double amplitude, double? at}) async =>
      0;
  @override
  Future<void> stop() async {}
  @override
  Future<void> speak(String? text) async {}
  @override
  Future<void> hold({required double frequency, required double amplitude}) async {}
  @override
  Future<void> release() async {}
  @override
  Future<double?> volume({int? deviceId}) async => null;
  @override
  Future<bool> setVolume(double volume, {int? deviceId}) async => false;
}

/// Epochs with an N1 on every tone and a P300 on rare ones, plus noise.
List<ErpEpoch> _epochs(int count) {
  final random = math.Random(4);
  double bump(double t, double centre, double width, double amplitude) =>
      amplitude * math.exp(-math.pow((t - centre) / width, 2) / 2);
  return [
    for (var n = 0; n < count; n++)
      ErpEpoch(
        StimulusEvent(onset: n.toDouble(), rare: n % 5 == 4),
        [
          for (var c = 0; c < 12; c++)
            Float64List.fromList([
              for (var i = 0; i < ErpEpoch.length; i++)
                bump(ErpEpoch.timeAt(i), 0.11, 0.025, -3 * (1 + c / 12)) +
                    (n % 5 == 4 ? bump(ErpEpoch.timeAt(i), 0.35, 0.08, 5 * (1 - c / 24)) : 0) +
                    6 * (random.nextDouble() - 0.5),
            ]),
        ],
        lostFraction: 0.2,
      ),
  ];
}

void main() {
  // MW75_RENDER=/path/to.png flutter test test/oddball_panel_test.dart
  final renderPath = Platform.environment['MW75_RENDER'];

  for (final (name, count) in [('results', 150), ('empty', 0)]) {
    testWidgets('lays out the oddball view without overflow ($name)', (tester) async {
      final loader = FontLoader('Roboto');
      for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
        final bytes = File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();

      final calibrations = SoundCalibrations();
      if (count > 0) {
        // Results with a calibrated output; the empty view shows an uncalibrated one.
        await calibrations.save(
          SoundCalibration(
            device: 'MW75 Neuro',
            date: DateTime(2026, 10, 9, 1, 30),
            volume: 0.5,
            points: const [
              CalibrationPoint(hz: 1000, dbfs: -30, spl: 62),
              CalibrationPoint(hz: 2000, dbfs: -30, spl: 65),
            ],
            levels: const [60, 70, 80],
          ),
        );
      }
      final session = OddballSession(
        headset: Mw75Headset(),
        tones: _SilentTones(),
        calibrations: calibrations,
        publishMarkers: false,
      )
        ..outputs = const [
          AudioOutputDevice(id: 1, name: 'MW75 Neuro', isDefault: true, bluetooth: true),
          AudioOutputDevice(id: 2, name: 'MacBook Pro Speakers', isDefault: false, bluetooth: false),
        ];
      if (count > 0) {
        session.runs.add(
          OddballRun(started: DateTime(2026, 10, 9, 2, 1), settings: const OddballSettings())
            ..output = 'MW75 Neuro'
            // Three more tones than epochs: two standard and one rare lost.
            ..trialsPlayed = count + 3
            ..raresPlayed = count ~/ 5 + 1
            ..epochs.addAll(_epochs(count))
            ..rejections[EpochRejection.lostData] = 3,
        );
      }
      addTearDown(session.dispose);

      final key = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(1120, 760));
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
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFFF7F7F8),
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
                      child: ListView(
                        children: [
                          card(
                            'Auditory oddball',
                            OddballControls(session: session, startBlockedReason: 'Start raw EEG in the Headset card first.'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            flex: 3,
                            child: card('Average response', ErpPanel(session: session, channels: List.generate(12, (i) => i)), expand: true),
                          ),
                          const SizedBox(height: 14),
                          Expanded(
                            flex: 2,
                            child: card(
                              'Each channel',
                              ErpChannelGrid(session: session, selected: 2, onSelected: (_) {}),
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
      if (count > 0) {
        expect(find.text('Rare (30)'), findsOneWidget);
        expect(find.text('Clear'), findsNWidgets(2));
        expect(find.text('Trials used'), findsOneWidget);
        expect(find.textContaining('3 too much data lost'), findsOneWidget);
        expect(find.text('70 dB SPL'), findsNothing);
        expect(find.text('Calibration…'), findsOneWidget);
      } else {
        expect(find.text('Calibrate…'), findsOneWidget);
        expect(find.text('Waiting'), findsNWidgets(2));
      }
      if (renderPath == null) return;
      await tester.runAsync(() async {
        final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(renderPath.replaceFirst('.png', '_$name.png')).writeAsBytesSync(png!.buffer.asUint8List());
      });
    });
  }

  testWidgets('dragging across the plot before onset sets the baseline; hovering reads it out', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      final bytes = File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
    final session = OddballSession(headset: Mw75Headset(), tones: _SilentTones(), publishMarkers: false);
    addTearDown(session.dispose);
    session.runs.add(
      OddballRun(started: DateTime(2026, 10, 9, 2, 1), settings: const OddballSettings())
        ..trialsPlayed = 150
        ..raresPlayed = 30
        ..epochs.addAll(_epochs(150)),
    );

    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(900, 520));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: ErpPanel(session: session, channels: List.generate(12, (i) => i)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('−200 to 0 ms'), findsOneWidget);

    final box = tester.getRect(find.byType(ErpPlot));
    final plot = Rect.fromLTRB(box.left + 44, box.top + 16, box.right, box.bottom - 20);
    Offset at(double seconds) =>
        Offset(plot.left + (seconds - ErpEpoch.start) / (ErpEpoch.end - ErpEpoch.start) * plot.width, plot.center.dy);

    final drag = await tester.startGesture(at(-0.15), kind: PointerDeviceKind.mouse);
    await drag.moveTo(at(-0.1));
    await drag.moveTo(at(-0.05));
    await drag.up();
    await tester.pump();
    expect(session.baseline, (-0.15, -0.05));
    expect(find.text('−150 to −50 ms (dragged)'), findsOneWidget);

    // Past onset the window stops at 0 ms.
    final across = await tester.startGesture(at(-0.1), kind: PointerDeviceKind.mouse);
    await across.moveTo(at(0.2));
    await across.moveTo(at(0.4));
    await across.up();
    await tester.pump();
    expect(session.baseline, (-0.1, 0.0));

    // Too short to be a window: ignored.
    final click = await tester.startGesture(at(-0.12), kind: PointerDeviceKind.mouse);
    await click.moveTo(at(-0.11));
    await click.up();
    await tester.pump();
    expect(session.baseline, (-0.1, 0.0));

    // The same mouse, button up, hovering at the P300.
    await click.moveTo(at(0.35));
    addTearDown(click.removePointer);
    await tester.pump();
    expect(tester.takeException(), isNull);
    if (renderPath == null) return;
    await tester.runAsync(() async {
      final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(renderPath.replaceFirst('.png', '_baseline.png')).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
