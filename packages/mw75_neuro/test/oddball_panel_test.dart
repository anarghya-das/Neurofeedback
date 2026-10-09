import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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

      final session = OddballSession(headset: Mw75Headset(), tones: _SilentTones(), publishMarkers: false)
        ..outputs = const [
          AudioOutputDevice(id: 1, name: 'MW75 Neuro', isDefault: true, bluetooth: true),
          AudioOutputDevice(id: 2, name: 'MacBook Pro Speakers', isDefault: false, bluetooth: false),
        ];
      if (count > 0) {
        session.runs.add(
          OddballRun(started: DateTime(2026, 10, 9, 2, 1), settings: const OddballSettings())
            ..output = 'MW75 Neuro'
            ..trialsPlayed = count
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
      } else {
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
}
