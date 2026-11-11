import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/src/app_window.dart';

void main() {
  group('reading the native full-screen reports', () {
    // The names macOS sends are the raw values of the AppKit notifications
    // MainFlutterWindow observes. If those lines change there, change these.
    test('a finished transition settles the state', () {
      expect(fullScreenFromLog('NSWindowDidEnterFullScreenNotification'), isTrue);
      expect(fullScreenFromLog('NSWindowDidExitFullScreenNotification'), isFalse);
    });

    test('a queued request is reported after the name, and does not confuse it', () {
      expect(
        fullScreenFromLog('NSWindowDidExitFullScreenNotification -> queued request: wanted true, full: false: toggled'),
        isFalse,
      );
    });

    test('a transition that has only started settles nothing', () {
      expect(fullScreenFromLog('NSWindowWillEnterFullScreenNotification'), isNull);
      expect(fullScreenFromLog('NSWindowWillExitFullScreenNotification'), isNull);
    });

    test('anything else settles nothing', () {
      expect(fullScreenFromLog(''), isNull);
      expect(fullScreenFromLog('wanted true, full: false: toggled'), isNull);
    });
  });

  test('the window starts out not full screen', () {
    expect(AppWindow.fullScreen.value, isFalse);
  });
}
