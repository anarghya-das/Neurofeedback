import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// Epochs with one clear bump, so turning the picture over is visible.
/// [sign] −1 gives the same data upside down.
List<ErpEpoch> _epochs({double sign = 1}) => [
  for (var e = 0; e < 12; e++)
    ErpEpoch(
      StimulusEvent(onset: 10.0 + e, rare: e.isEven),
      [
        for (var c = 0; c < 12; c++)
          Float64List.fromList([
            for (var i = 0; i < ErpEpoch.length; i++)
              sign * (e.isEven ? 8 : 5) * math.sin(i / ErpEpoch.length * math.pi),
          ]),
      ],
      lostFraction: 0,
    ),
];

ErpSummary _summary({double sign = 1}) => ErpSummary.compute(_epochs(sign: sign), const [0], tests: false);

/// The raw pixels of a compact plot, which draws traces and axes only — no
/// text, so this does not depend on fonts.
Future<Uint8List> _render(WidgetTester tester, ErpSummary summary, ErpPolarity polarity) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: SizedBox(
            width: 240,
            height: 120,
            child: ErpPlot(summary: summary, range: 10, compact: true, polarity: polarity),
          ),
        ),
      ),
    ),
  );
  late Uint8List pixels;
  await tester.runAsync(() async {
    final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage();
    pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  });
  return pixels;
}

void main() {
  test('the sign is the only difference between the two polarities', () {
    expect(ErpPolarity.positiveUp.sign, 1);
    expect(ErpPolarity.positiveDown.sign, -1);
    expect(ErpPolarity.positiveUp.label, 'Positive up');
    expect(ErpPolarity.positiveDown.label, 'Positive down');
  });

  testWidgets('positive down draws the data the same way up as negating it would', (tester) async {
    final down = await _render(tester, _summary(), ErpPolarity.positiveDown);
    final negatedUp = await _render(tester, _summary(sign: -1), ErpPolarity.positiveUp);
    expect(down, negatedUp);
  });

  testWidgets('the polarity actually changes the picture', (tester) async {
    final up = await _render(tester, _summary(), ErpPolarity.positiveUp);
    final down = await _render(tester, _summary(), ErpPolarity.positiveDown);
    expect(down, isNot(up));
  });

  test('the measured values are untouched by the polarity', () {
    // Only the drawing flips: a positive bump stays positive in the summary,
    // which is what the readout and the tests report.
    final s = _summary();
    expect(ErpSummary.windowMean(s.rareMean, ErpSummary.responseWindow), greaterThan(0));
  });
}
