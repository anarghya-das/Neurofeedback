import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// Fails the test if anything tries to play sound.
class _NoTones implements ToneOutput {
  final calls = <String>[];

  @override
  Future<List<AudioOutputDevice>> devices() async => const [];
  @override
  Future<ToneOutputInfo> start({int? deviceId}) async {
    calls.add('start');
    return const ToneOutputInfo(device: '', bluetooth: false, sampleRate: 48000, latency: 0);
  }

  @override
  Future<double> play({required double frequency, required double duration, required double amplitude, double? at}) async {
    calls.add('play');
    return 0;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> speak(String? text) async {}
  @override
  Future<void> hold({required double frequency, required double amplitude}) async {}
  @override
  Future<void> release() async {}
  @override
  Future<double?> volume({int? deviceId}) async => null;
  @override
  Future<bool> setVolume(double volume, {int? deviceId}) async => false;
}

void main() {
  // On Windows the app has no tone player, and the first Windows test showed a
  // run that sat on the dot screen forever. Without tones the test is refused
  // up front instead.
  test('without tones, start and preview say why and never become busy', () async {
    final tones = _NoTones();
    final session = OddballSession(headset: Mw75Headset(), tones: tones, publishMarkers: false, tonesAvailable: false);
    addTearDown(session.dispose);

    expect(session.unavailableReason, contains("isn't available on Windows yet"));

    await session.start();
    expect(session.busy, isFalse);
    expect(session.state, OddballState.idle);
    expect(session.statusText, session.unavailableReason);

    await session.preview();
    expect(session.busy, isFalse);
    expect(tones.calls, isEmpty);
  });

  test('with tones the test is not refused', () {
    final session = OddballSession(headset: Mw75Headset(), tones: _NoTones(), publishMarkers: false, tonesAvailable: true);
    addTearDown(session.dispose);
    expect(session.unavailableReason, isNull);
  });

  testWidgets('the panel shows the reason and disables Start test, Preview and Calibrate', (tester) async {
    final session = OddballSession(headset: Mw75Headset(), tones: _NoTones(), publishMarkers: false, tonesAvailable: false)
      ..outputs = const [AudioOutputDevice(id: 1, name: 'Speakers', isDefault: true, bluetooth: false)];
    addTearDown(session.dispose);

    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 340, child: OddballControls(session: session)),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(session.unavailableReason!), findsOneWidget);
    ButtonStyleButton button(String label) =>
        tester.widget<ButtonStyleButton>(find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()));
    expect(button('Start test').onPressed, isNull);
    expect(button('Preview').onPressed, isNull);
    expect(button('Calibrate…').onPressed, isNull);
  });
}
