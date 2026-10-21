import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

FocusWindow _window(List<double> means, math.Random random) => FocusWindow(
  start: 0,
  end: 2,
  features: Float64List.fromList([for (final m in means) m + 0.25 * (random.nextDouble() - 0.5) * 3]),
  muscle: 0.5,
  broadband: 1,
  lostFraction: 0,
);

void main() {
  // MW75_RENDER=/path/to.png flutter test test/focus_page_test.dart
  testWidgets('the focus page lays out its controls, score and timeline', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      loader.addFont(
        Future.value(ByteData.sublistView(File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync())),
      );
    }
    await loader.load();
    final random = math.Random(3);
    final rest = List.filled(36, 1.0);
    final focused = [for (var i = 0; i < 36; i++) i % 3 == 1 && i ~/ 3 >= 6 ? 0.5 : (i % 3 == 0 ? 1.2 : 1.0)];
    final session = FocusSession(headset: Mw75Headset(), publishToLsl: false)
      ..model = FocusModel.train(
        focusBlocks: [
          for (var b = 0; b < 4; b++) [for (var w = 0; w < 40; w++) _window(focused, random)],
        ],
        restBlocks: [
          for (var b = 0; b < 4; b++) [for (var w = 0; w < 40; w++) _window(rest, random)],
        ],
        now: DateTime(2026, 10, 12, 9, 30),
      )
      ..score = 72
      ..target = 58
      ..scoredSeconds = 280
      ..secondsAboveTarget = 190;
    for (var i = 0; i < 600; i++) {
      session.history.add(
        FocusPoint(1000 + i * 0.5, 50 + 30 * math.sin(i / 60), noisy: i > 380 && i < 400, target: i < 300 ? 50 : 58),
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
        theme: ThemeData(fontFamily: 'Roboto'),
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
                    child: ListView(children: [card('Your focus', FocusControls(session: session))]),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(flex: 3, child: card('Focus now', FocusScoreView(session: session), expand: true)),
                        const SizedBox(height: 14),
                        Expanded(
                          flex: 2,
                          child: card('Over the last 5 minutes', FocusTimeline(session: session), expand: true),
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
    // The animation never settles: let the fire build for a couple of seconds.
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('72'), findsOneWidget);
    expect(find.text('At or above your target'), findsOneWidget);
    expect(find.textContaining('68% of the time (3 min 10 s of 4 min 40 s)'), findsOneWidget);
    expect(find.text('Recalibrate'), findsOneWidget);
    expect(find.textContaining('Alpha, right cup'), findsOneWidget);
    // Before any clean window: say why instead of waiting silently.
    session
      ..score = null
      ..noisy = true
      ..lastLostFraction = 0.38;
    session.notifyListeners();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('No clean EEG to score yet'), findsOneWidget);
    expect(find.textContaining('38% of the EEG was lost over Bluetooth (scoring needs under 30%)'), findsOneWidget);
    expect(find.text('No clean EEG yet'), findsOneWidget);
    final renderPath = Platform.environment['MW75_RENDER'];
    if (renderPath != null) {
      await tester.runAsync(() async {
        final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
        File(
          renderPath,
        ).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      });
    }
    await tester.pumpWidget(const SizedBox());
  });
}
