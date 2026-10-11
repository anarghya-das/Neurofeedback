import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// 31 s of 12 channels: 10 Hz rhythm, noise and offsets, a blink-like spike on Ch3.
EegPlotBuffer _buffer(double t0) {
  final buffer = EegPlotBuffer(seconds: EegTracePainter.maxWindow);
  final random = math.Random(1);
  const rate = 496.5;
  buffer.addAll([
    for (var i = 0; i < (31 * rate).round(); i++)
      () {
        final t = i / rate;
        return Mw75Sample(
          [
            for (var c = 0; c < 12; c++)
              300.0 * c +
                  (10 + c) * math.sin(2 * math.pi * 10 * t + c) +
                  6 * (random.nextDouble() - 0.5) +
                  (c == 2 && (t % 7) < 0.15 ? 120 * math.sin(math.pi * (t % 7) / 0.15) : 0),
            0,
            0,
            i.toDouble(),
            0,
          ],
          t0 + t,
          status: SampleStatus.measured,
        );
      }(),
  ]);
  return buffer;
}

void main() {
  // MW75_RENDER=/path/to.png flutter test test/live_eeg_plot_test.dart
  for (final (window, scale, name) in [(4.0, 50.0, '4s'), (30.0, 100.0, '30s'), (4.0, null, 'auto')]) {
    testWidgets('draws lanes, axes and the hover readout ($name)', (tester) async {
      final loader = FontLoader('Roboto');
      for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
        loader.addFont(
          Future.value(ByteData.sublistView(File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync())),
        );
      }
      await loader.load();
      const t0 = 1000.0;
      final buffer = _buffer(t0);
      final auto = EegAutoScale();
      final key = GlobalKey();
      final repaint = ChangeNotifier();
      addTearDown(repaint.dispose);
      Offset? hover;
      await tester.binding.setSurfaceSize(const Size(1100, 560));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(18),
                child: StatefulBuilder(
                  builder: (context, setState) => MouseRegion(
                    onHover: (e) => setState(() => hover = e.localPosition),
                    child: CustomPaint(
                      painter: EegTracePainter(
                        buffer,
                        repaint: repaint,
                        window: window,
                        halfRangeUv: scale ?? 100,
                        autoScale: scale == null ? auto : null,
                        hover: hover,
                        clock: () => t0 + 31,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 100));
      await mouse.moveTo(const Offset(600, 120));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (scale == null) {
        // Each channel spans its own min..max: Ch12's 21 µV rhythm sits on 3300 µV.
        final (lo, hi) = auto.limits[11]!;
        expect(lo, greaterThan(3250));
        expect(hi, lessThan(3350));
        expect(hi - lo, greaterThan(40));
      }
      final renderPath = Platform.environment['MW75_RENDER'];
      if (renderPath == null) return;
      await tester.runAsync(() async {
        final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
        File(
          renderPath.replaceFirst('.png', '_$name.png'),
        ).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      });
    });
  }
}
