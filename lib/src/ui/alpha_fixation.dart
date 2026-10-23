import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../alpha_test.dart';

/// What the participant sees during an eyes-closed alpha run: a plain grey
/// screen with one dot to look at, so nothing on screen draws the eyes while
/// they are open. The cues are spoken. It closes itself when the run ends;
/// Esc or the corner button stops the run.
class AlphaFixationScreen extends StatefulWidget {
  const AlphaFixationScreen({super.key, required this.session});

  final AlphaSession session;

  static Route<void> route(AlphaSession session) => PageRouteBuilder<void>(
    opaque: true,
    pageBuilder: (context, animation, secondaryAnimation) => AlphaFixationScreen(session: session),
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );

  @override
  State<AlphaFixationScreen> createState() => _AlphaFixationScreenState();
}

class _AlphaFixationScreenState extends State<AlphaFixationScreen> {
  static const _background = Color(0xFF808080);
  static const _dot = Color(0xFF111216);
  static const _faint = Color(0xFF5E5E5E);

  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (widget.session.busy) {
      setState(() {});
    } else {
      _close();
    }
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).maybePop();
  }

  void _stop() {
    if (widget.session.busy) widget.session.stop();
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final preparing = widget.session.state == AlphaState.preparing;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _stop},
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: _background,
          body: Stack(
            children: [
              Center(
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: const BoxDecoration(color: _dot, shape: BoxShape.circle),
                ),
              ),
              if (preparing)
                const Align(
                  alignment: Alignment(0, 0.35),
                  child: Text(
                    'Look at the dot. Follow the spoken cues to open and close your eyes.',
                    style: TextStyle(fontSize: 15, color: _faint),
                  ),
                ),
              Positioned(
                top: 12,
                right: 12,
                child: TextButton(
                  onPressed: _stop,
                  style: TextButton.styleFrom(foregroundColor: _faint),
                  child: const Text('Stop (Esc)', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
