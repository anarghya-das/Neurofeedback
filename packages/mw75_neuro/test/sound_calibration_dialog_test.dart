import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// Holds steady tones and reports a fixed Mac volume.
class _MeterTones implements ToneOutput {
  final held = <(double, double)>[];
  bool holding = false;

  @override
  Future<List<AudioOutputDevice>> devices() async => const [
    AudioOutputDevice(id: 1, name: 'MW75 Neuro', isDefault: true, bluetooth: true),
  ];
  @override
  Future<ToneOutputInfo> start({int? deviceId}) async =>
      const ToneOutputInfo(device: 'MW75 Neuro', bluetooth: true, sampleRate: 48000, latency: 0);
  @override
  Future<double> play({required double frequency, required double duration, required double amplitude, double? at}) async =>
      0;
  @override
  Future<void> stop() async => holding = false;
  @override
  Future<void> speak(String? text) async {}
  @override
  Future<void> hold({required double frequency, required double amplitude}) async {
    held.add((frequency, amplitude));
    holding = true;
  }

  @override
  Future<void> release() async => holding = false;
  @override
  Future<double?> volume({int? deviceId}) async => 0.5;
  @override
  Future<bool> setVolume(double volume, {int? deviceId}) async => true;
}

void main() {
  // MW75_RENDER=/path/to.png flutter test test/sound_calibration_dialog_test.dart
  final renderPath = Platform.environment['MW75_RENDER'];

  testWidgets('walks through calibrating an output and then sets levels in dB SPL', (tester) async {
    final loader = FontLoader('Roboto');
    for (final file in ['Arial.ttf', 'Arial Bold.ttf']) {
      final bytes = File('/System/Library/Fonts/Supplemental/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();

    final tones = _MeterTones();
    final session = OddballSession(headset: Mw75Headset(), tones: tones, publishMarkers: false);
    addTearDown(session.dispose);
    await session.refreshOutputs();

    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorSchemeSeed: const Color(0xFF111216)),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 340,
                child: SingleChildScrollView(
                  child: OddballControls(session: session),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    Future<void> render(String name) async {
      if (renderPath == null) return;
      await tester.runAsync(() async {
        final image = await tester.renderObject<RenderRepaintBoundary>(find.byKey(key)).toImage(pixelRatio: 1.5);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File(renderPath.replaceFirst('.png', '_$name.png')).writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    final readings = find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == '—');

    // Uncalibrated: a relative level.
    expect(find.text('Calibrate…'), findsOneWidget);
    expect(find.textContaining('is not calibrated'), findsOneWidget);
    await tester.tap(find.text('Calibrate…'));
    await tester.pumpAndSettle();

    // 1. Get ready.
    expect(find.text('Calibrate the sound level'), findsOneWidget);
    expect(find.textContaining('It is at 50% now'), findsOneWidget);
    await render('step1');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 2. A reading per tone, at the default −30 dB.
    expect(find.text('1000 Hz tone'), findsOneWidget);
    await tester.tap(find.text('Play').first);
    await tester.pump();
    expect(tones.held.last.$1, 1000);
    expect(tones.held.last.$2, closeTo(amplitudeForDbfs(-30), 1e-12));
    expect(find.text('Stop'), findsOneWidget);
    await tester.enterText(readings.at(0), '62');
    await tester.tap(find.text('Save reading').first);
    await tester.pump();
    expect(find.textContaining('plays up to 92 dB SPL'), findsOneWidget);
    // Next waits for the second tone.
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('2000 Hz tone'), findsOneWidget);

    await tester.tap(find.text('Play').last);
    await tester.pump();
    expect(tones.held.last.$1, 2000);
    await tester.enterText(readings.at(1), '65');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 500));
    await render('step2');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 3. Add 70 dB SPL and check it: 1000 Hz plays at −22 dB and reads 1.5 dB
    // high, which corrects the calibration.
    await tester.tap(find.text('Add level'));
    await tester.pump();
    expect(find.text('70 dB SPL'), findsOneWidget);
    await tester.tap(find.text('Play').first);
    await tester.pump();
    expect(tones.held.last.$2, closeTo(amplitudeForDbfs(-22), 1e-12));
    await tester.enterText(readings.at(0), '71.5');
    await tester.tap(find.text('Save reading').first);
    await tester.pump();
    expect(find.text('Read 71.5: corrected, play again to check'), findsOneWidget);
    await tester.tap(find.text('Play').first);
    await tester.pump();
    // Between the readings (−30 dB, 62) and (−22 dB, 71.5).
    expect(tones.held.last.$2, closeTo(amplitudeForDbfs(-30 + 8 * 8 / 9.5), 1e-9));
    await tester.enterText(readings.at(0), '70.2');
    await tester.tap(find.text('Save reading').first);
    await tester.pump();
    expect(find.text('Read 70.2: within 1 dB'), findsOneWidget);
    await tester.tap(find.text('+ 60'));
    await tester.pump();
    await render('step3');

    await tester.tap(find.text('Save calibration'));
    await tester.pumpAndSettle();
    expect(find.text('Calibrate the sound level'), findsNothing);
    expect(tones.holding, isFalse);

    // Calibrated: the level is in dB SPL, with the checked levels as quick picks.
    final c = session.calibration!;
    expect(c.device, 'MW75 Neuro');
    expect(c.volume, 0.5);
    expect(c.levels, [60, 70]);
    expect(find.text('Calibration…'), findsOneWidget);
    expect(find.text('dB SPL'), findsOneWidget);
    await tester.tap(find.text('60 dB'));
    await tester.pump();
    expect(session.settings.levelSpl, 60);
    expect(session.levelsFor(session.settings).standard, closeTo(-32, 1e-9));
    await render('panel');
  });
}
