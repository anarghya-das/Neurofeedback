import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

const b = ContactQuality.best;
const g = ContactQuality.good;
const a = ContactQuality.acceptable;
const x = ContactQuality.bad;

/// The ratings in the Research Kit screenshot this layout was matched against.
final screenshotQuality = Mw75SignalQuality(
  ref: b,
  drl: b,
  channels: [x, a, b, a, x, x, x, b, b, b, x, x],
);

void main() {
  group('sideQuality', () {
    Mw75SignalQuality withBadLeft(int count) => Mw75SignalQuality(
      ref: x, // Ref and DRL never count towards a cup's summary.
      drl: x,
      channels: [for (var i = 0; i < 12; i++) i < count ? x : g],
    );

    test('is checking until the first report', () {
      expect(
        sideQuality(null, EarSide.left, QualityStrictness.standard),
        isNull,
      );
    });

    test('applies Research Kit thresholds per cup', () {
      expect(
        sideQuality(withBadLeft(0), EarSide.left, QualityStrictness.strict),
        b,
      );
      expect(
        sideQuality(withBadLeft(1), EarSide.left, QualityStrictness.strict),
        x,
      );
      expect(
        sideQuality(withBadLeft(1), EarSide.left, QualityStrictness.standard),
        b,
      );
      expect(
        sideQuality(withBadLeft(2), EarSide.left, QualityStrictness.standard),
        x,
      );
      expect(
        sideQuality(withBadLeft(3), EarSide.left, QualityStrictness.lenient),
        b,
      );
      expect(
        sideQuality(withBadLeft(4), EarSide.left, QualityStrictness.lenient),
        x,
      );
    });

    test('only counts the cup’s own channels and ignores Ref/DRL', () {
      expect(
        sideQuality(withBadLeft(6), EarSide.right, QualityStrictness.strict),
        b,
      );
    });

    test(
      'matches the Research Kit screenshot: both cups bad under Standard',
      () {
        expect(
          sideQuality(
            screenshotQuality,
            EarSide.left,
            QualityStrictness.standard,
          ),
          x,
        );
        expect(
          sideQuality(
            screenshotQuality,
            EarSide.right,
            QualityStrictness.standard,
          ),
          x,
        );
        expect(
          sideQuality(
            screenshotQuality,
            EarSide.left,
            QualityStrictness.lenient,
          ),
          b,
        );
      },
    );
  });

  // Renders the map to a PNG for a visual check against Research Kit.
  // MW75_RENDER=/path/to.png flutter test test/ear_cup_map_test.dart
  final renderPath = Platform.environment['MW75_RENDER'];
  for (final (name, quality, width) in [
    ('streaming', screenshotQuality, 344.0),
    ('checking', null, 324.0),
  ]) {
    testWidgets('renders the ear-cup map ($name, ${width.toInt()} px)', (
      tester,
    ) async {
      // Real glyphs instead of the test font's boxes, so the render is readable.
      final loader = FontLoader('Roboto');
      for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
        final bytes = File(
          '/System/Library/Fonts/Supplemental/$file',
        ).readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
      final key = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(420, 420));
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: Container(
                  color: Colors.white,
                  width: width,
                  child: EarCupQualityMap(
                    quality: quality,
                    strictness: QualityStrictness.standard,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          quality == null
              ? 'General quality: Checking'
              : 'General quality: Bad',
        ),
        findsNWidgets(2),
      );
      if (renderPath == null) return;
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          renderPath.replaceFirst('.png', '_$name.png'),
        ).writeAsBytesSync(png!.buffer.asUint8List());
      });
    });
  }
}
