import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Window controls the app implements itself, without a plugin package:
/// macOS in `macos/Runner/MainFlutterWindow.swift`, Windows in
/// `windows/runner/flutter_window.cpp`.
abstract final class AppWindow {
  static const _channel = MethodChannel('mw75_bench/window');
  static var _listening = false;

  /// Whether the window is in full screen, as far as this side can tell: what
  /// was last asked for, corrected by the transitions macOS reports — there the
  /// user can also leave full screen themselves, with the green button or
  /// Control-Command-F. Windows reports nothing and offers no such control, so
  /// there the last request is the whole truth.
  static final fullScreen = ValueNotifier(false);

  /// Starts taking the native side's reports. Safe to call more than once; call
  /// it at startup, so the state is right even if full screen begins somewhere
  /// other than a test screen.
  static void listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'log') return;
      final line = '${call.arguments}';
      debugPrint('[window] native: $line');
      final now = fullScreenFromLog(line);
      if (now != null) fullScreen.value = now;
    });
  }

  /// Puts the app window into or out of full screen. Does nothing where there
  /// is no native handler (widget tests, other platforms).
  static Future<void> setFullScreen(bool value) async {
    listen();
    try {
      final did = await _channel.invokeMethod<Object?>('setFullScreen', {'value': value});
      debugPrint('[window] setFullScreen($value): ${did ?? 'done'}');
      fullScreen.value = value;
    } on MissingPluginException {
      // No native side here; the test screen still fills the window.
    } on PlatformException catch (e) {
      debugPrint('[window] full screen failed: ${e.message ?? e.code}');
    }
  }
}

/// What a line from the native side says the window is now, or null when it
/// says nothing about that. macOS sends the names of the AppKit notifications
/// it sees (`MainFlutterWindow.observeFullScreenTransitions`), sometimes with
/// more after them; only a finished transition settles the state.
bool? fullScreenFromLog(String line) {
  if (line.startsWith('NSWindowDidEnterFullScreen')) return true;
  if (line.startsWith('NSWindowDidExitFullScreen')) return false;
  return null;
}
