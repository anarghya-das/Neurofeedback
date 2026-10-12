import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

void main() {
  group('FocusSession.targetFor', () {
    List<FocusPoint> history(double Function(int) score, {int n = 360, bool Function(int)? noisy}) => [
      for (var i = 0; i < n; i++) FocusPoint(i * 0.5, score(i), noisy: noisy?.call(i) ?? false),
    ];

    test('is the 30th percentile of the last 3 minutes of clean scores', () {
      // Scores 0–99 repeating; the last 3 min are 360 points at 2 per second.
      final points = history((i) => (i % 100).toDouble(), n: 1000);
      expect(FocusSession.targetFor(points, points.last.time), closeTo(41, 2));
    });

    test('waits for about a minute of clean scores', () {
      expect(FocusSession.targetFor(history((_) => 60, n: 90), 45), isNull);
      // Noisy points do not count.
      expect(FocusSession.targetFor(history((_) => 60, n: 180, noisy: (i) => i.isOdd), 90), isNull);
      expect(FocusSession.targetFor(history((_) => 60), 180), 60);
    });

    test('never drops low enough to reward rest-like EEG, nor out of reach', () {
      expect(FocusSession.targetFor(history((_) => 5), 180), FocusSession.targetRange.$1);
      expect(FocusSession.targetFor(history((_) => 98), 180), FocusSession.targetRange.$2);
    });
  });

  // MW75_RENDER=/path/prefix flutter test test/focus_visuals_test.dart
  testWidgets('the flame and the rocket draw every focus level, moving and still', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      loader.addFont(
        Future.value(ByteData.sublistView(File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync())),
      );
    }
    await loader.load();
    final renderPrefix = Platform.environment['MW75_RENDER'];
    await tester.binding.setSurfaceSize(const Size(1240, 560));
    for (final still in [false, true]) {
      for (final visual in FocusVisual.values) {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'Roboto'),
            home: Material(
              child: MediaQuery(
                data: MediaQueryData(size: const Size(1240, 560), disableAnimations: still),
                child: RepaintBoundary(
                  key: key,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        for (final (level, paused) in const [
                          (null, false),
                          (0.1, false),
                          (0.45, false),
                          (0.9, false),
                          (0.6, true),
                        ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: FocusVisualView(
                                visual: visual,
                                level: level,
                                target: 0.5,
                                paused: paused,
                                climbSeconds: 125,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        // Three seconds of animation for the fire to build up.
        for (var i = 0; i < 180; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull);
        expect(find.text('Waiting for a score'), findsOneWidget);
        expect(find.text('Paused: too noisy'), findsOneWidget);
        // No altitude until there is a score.
        if (visual == FocusVisual.rocket) expect(find.text('Altitude 1250 m'), findsNWidgets(4));
        if (renderPrefix != null) {
          await tester.runAsync(() async {
            final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
            File(
              '$renderPrefix-${visual.name}${still ? '-still' : ''}.png',
            ).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
          });
        }
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
