import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

void main() {
  test('the quick checks take about a minute and still give each block usable windows', () {
    expect(AlphaSettings.quick.duration.inSeconds, lessThanOrEqualTo(60));
    expect(FocusCalibrationSettings.quick.duration.inSeconds, lessThanOrEqualTo(60));
    expect(AlphaSettings.quick.isQuick, isTrue);
    expect(const AlphaSettings().isQuick, isFalse);
    expect(FocusCalibrationSettings.quick.isQuick, isTrue);
    expect(const FocusCalibrationSettings().isQuick, isFalse);

    // Focus needs two usable blocks of each with at least 12 windows (~0.5 s
    // apart) after the settling time; the quick blocks leave about 24.
    final focus = FocusCalibrationSettings.quick;
    expect(focus.blocksPerCondition, greaterThanOrEqualTo(2));
    expect((focus.blockSeconds - focus.settleSeconds) / 0.5, greaterThanOrEqualTo(2 * FocusModel.minBlockWindows));
  });

  testWidgets('the alpha quick check switches the run length and back', (tester) async {
    final session = AlphaSession(headset: Mw75Headset());
    addTearDown(session.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SizedBox(width: 340, child: AlphaControls(session: session))),
        ),
      ),
    );

    await tester.tap(find.byType(QuickCheckToggle));
    await tester.pump();
    expect(session.settings.isQuick, isTrue);

    // Picking a full length turns the quick check off.
    await tester.tap(find.textContaining('8 each'));
    await tester.pump();
    expect(session.settings.isQuick, isFalse);
    expect(session.settings.blocksPerCondition, 8);
    expect(session.settings.blockSeconds, const AlphaSettings().blockSeconds);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the focus quick check switches the calibration length and back', (tester) async {
    final session = FocusSession(headset: Mw75Headset(), publishToLsl: false);
    addTearDown(session.dispose);
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: SizedBox(width: 340, child: FocusControls(session: session))),
        ),
      ),
    );

    await tester.tap(find.byType(QuickCheckToggle));
    await tester.pump();
    expect(session.settings.isQuick, isTrue);

    await tester.tap(find.byType(QuickCheckToggle));
    await tester.pump();
    expect(session.settings.isQuick, isFalse);
    expect(session.settings.blockSeconds, const FocusCalibrationSettings().blockSeconds);
    expect(tester.takeException(), isNull);
  });
}
