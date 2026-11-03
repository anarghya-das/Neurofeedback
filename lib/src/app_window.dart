import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Window controls the app implements itself, without a plugin package:
/// macOS in `macos/Runner/MainFlutterWindow.swift`, Windows in
/// `windows/runner/flutter_window.cpp`.
abstract final class AppWindow {
  static const _channel = MethodChannel('mw75_bench/window');
  static var _listening = false;

  /// Puts the app window into or out of full screen. Does nothing where there
  /// is no native handler (widget tests, other platforms).
  static Future<void> setFullScreen(bool value) async {
    if (!_listening) {
      _listening = true;
      // The native side reports full-screen transitions, for diagnosing them.
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'log') debugPrint('[window] native: ${call.arguments}');
      });
    }
    try {
      final did = await _channel.invokeMethod<Object?>('setFullScreen', {'value': value});
      debugPrint('[window] setFullScreen($value): ${did ?? 'done'}');
    } on MissingPluginException {
      // No native side here; the test screen still fills the window.
    } on PlatformException catch (e) {
      debugPrint('[window] full screen failed: ${e.message ?? e.code}');
    }
  }
}
