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

/// 1/f background, a 10 Hz alpha peak of a different size per channel, and
/// the dip a 60 Hz notch leaves.
PowerSpectrum _spectrum(int channel) {
  const binHz = 496.5 / 512;
  final density = Float64List(257);
  for (var k = 1; k < density.length; k++) {
    final f = k * binHz;
    density[k] = 40 / f + (2 + channel) * math.exp(-math.pow((f - 10) / 1.2, 2) / 2) + 0.05;
    if ((f - 60).abs() < 1.5) density[k] *= 0.02;
  }
  return PowerSpectrum(binHz: binHz, density: density, channelsUsed: 1);
}

void main() {
  // MW75_RENDER=/path/to.png flutter test test/spectrum_plot_test.dart
  testWidgets('one line per channel with a legend and a hover readout', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      loader.addFont(
        Future.value(ByteData.sublistView(File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync())),
      );
    }
    await loader.load();
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(900, 300));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(18),
              child: ChannelSpectrumPlot(
                spectrum: [for (var c = 0; c < 12; c++) (c, _spectrum(c))],
                filters: const EegFilterSettings(),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Ch1'), findsOneWidget);
    expect(find.text('Ch12'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 150));
    await mouse.moveTo(const Offset(170, 150));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final renderPath = Platform.environment['MW75_RENDER'];
    Future<void> render(String suffix) async {
      if (renderPath == null) return;
      await tester.runAsync(() async {
        final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
        File(
          renderPath.replaceFirst('.png', '$suffix.png'),
        ).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      });
    }

    await render('');
    // Restricting the range to 30 Hz.
    await tester.tap(find.text('30 Hz'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await render('_30hz');
  });
}
