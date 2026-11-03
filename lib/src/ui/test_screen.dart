import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_window.dart';

/// Grey background for screens with a fixation dot. Black is also used in
/// some labs; grey was agreed as fine for these tests.
const testScreenGrey = Color(0xFF808080);

/// What the participant sees during a test: the whole screen (true full screen
/// on macOS and Windows), with a centred fixation dot and a large instruction
/// below it, or with [body] instead of the dot. No timers, so nothing on screen
/// competes with the dot.
///
/// When [closeWhenDone] is true it closes itself once [isRunning] turns false.
/// Esc or the corner button stops a running test ([onStop]) and closes it.
class TestScreen extends StatefulWidget {
  const TestScreen({
    super.key,
    required this.listenable,
    required this.isRunning,
    required this.onStop,
    this.instruction,
    this.body,
    this.background = testScreenGrey,
    this.closeWhenDone = true,
  });

  /// Rebuilds the screen and checks [isRunning] when it notifies.
  final Listenable listenable;
  final bool Function() isRunning;
  final VoidCallback onStop;

  /// The current instruction under the dot, or null for none.
  final String? Function()? instruction;

  /// Shown instead of the dot and instruction.
  final WidgetBuilder? body;
  final Color background;
  final bool closeWhenDone;

  static Route<void> route(TestScreen screen) => PageRouteBuilder<void>(
    opaque: true,
    pageBuilder: (context, animation, secondaryAnimation) => screen,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  static const _dot = Color(0xFF111216);
  static const _faint = Color(0xFF5E5E5E);

  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onChange);
    AppWindow.setFullScreen(true);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChange);
    AppWindow.setFullScreen(false);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (widget.closeWhenDone && !widget.isRunning()) {
      _close();
    } else {
      setState(() {});
    }
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  void _stop() {
    if (widget.isRunning()) widget.onStop();
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final running = widget.isRunning();
    final instruction = widget.instruction?.call();
    final light = widget.background.computeLuminance() > 0.5;
    final text = light ? const Color(0xFF3A3D44) : const Color(0xFF202226);
    final body = widget.body;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _stop},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: widget.background,
          body: Stack(
            children: [
              if (body != null)
                Positioned.fill(child: body(context))
              else ...[
                // The dot stays at the exact centre; the instruction sits below it.
                Center(
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(color: _dot, shape: BoxShape.circle),
                  ),
                ),
                if (instruction != null)
                  Align(
                    alignment: const Alignment(0, 0.4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 48),
                      child: Text(
                        instruction,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w600, color: text, height: 1.3),
                      ),
                    ),
                  ),
              ],
              Positioned(
                top: 12,
                right: 12,
                child: TextButton(
                  onPressed: _stop,
                  style: TextButton.styleFrom(foregroundColor: _faint),
                  child: Text(running ? 'Stop (Esc)' : 'Exit full screen (Esc)', style: const TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
