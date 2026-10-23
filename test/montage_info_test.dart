import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

import 'support/system_fonts.dart';

void main() {
  // MW75_RENDER=/path/to.png flutter test test/montage_info_test.dart
  testWidgets('the info button explains the montages', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(systemFontPath(file)).readAsBytesSync())),
      );
    }
    await loader.load();
    await tester.binding.setSurfaceSize(const Size(900, 900));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        // Around the navigator, so the capture includes the dialog.
        builder: (context, child) => RepaintBoundary(key: key, child: child),
        home: const Scaffold(body: Center(child: MontageInfoButton())),
      ),
    );
    await tester.tap(find.byType(MontageInfoButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Channels and montages'), findsOneWidget);
    expect(find.textContaining('Ch2 − Ch5', findRichText: true), findsOneWidget);
    final renderPath = Platform.environment['MW75_RENDER'];
    if (renderPath != null) {
      await tester.runAsync(() async {
        final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
        File(
          renderPath,
        ).writeAsBytesSync((await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
      });
    }
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Channels and montages'), findsNothing);
  });
}
