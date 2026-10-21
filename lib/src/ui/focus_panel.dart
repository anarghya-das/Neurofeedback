import 'package:flutter/material.dart';

import '../metric_session.dart';
import 'cup_contact.dart';

const _muted = Color(0xFF69707D);

/// Focus score and the headset's own per-cup contact level from the metrics
/// session, styled after Research Kit's metrics view (same thresholds and
/// labels, Tailwind v4 colours converted to sRGB).
class FocusPanel extends StatelessWidget {
  const FocusPanel({super.key, required this.session, this.startBlockedReason});

  final Mw75MetricSession session;

  /// When non-null the start button is disabled and this explains why (for
  /// example, raw EEG streaming is using the headset).
  final String? startBlockedReason;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final running = session.state == MetricState.running;
        // While the headset has paused the session its last values are stale.
        final live = running && !session.paused;
        final busy = session.state == MetricState.connecting || session.state == MetricState.stopping;
        final blocked = !running && !busy && startBlockedReason != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _FocusScore(value: live ? session.focus : null, paused: running && session.paused),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                CupContactLevel(side: 'Left', level: live ? session.leftContact : null),
                CupContactLevel(side: 'Right', level: live ? session.rightContact : null),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 34,
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy || blocked ? null : (running ? session.stop : session.start),
                icon: busy
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: Color(0xFF9CA3AF)),
                      )
                    : Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 15),
                label: Text(
                  switch (session.state) {
                    MetricState.connecting => 'Starting…',
                    MetricState.stopping => 'Stopping…',
                    MetricState.running => 'Stop Focus',
                    _ => 'Start Focus',
                  },
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  backgroundColor: const Color(0xFF080615),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFF2F2F5),
                  disabledForegroundColor: const Color(0xFF9CA3AF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              blocked ? startBlockedReason! : session.statusText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: session.state == MetricState.error && !blocked ? const Color(0xFFB42318) : _muted,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FocusScore extends StatelessWidget {
  const _FocusScore({required this.value, this.paused = false});

  /// 0–1 from the headset, or null before the first record.
  final double? value;

  /// The headset has paused the session (it was lifted off the head).
  final bool paused;

  // Research Kit: green from 65, amber from 40, red below.
  static Color _colour(int score) => score >= 65
      ? const Color(0xFF00BC7D)
      : score >= 40
      ? const Color(0xFFFFB900)
      : const Color(0xFFFF6467);

  @override
  Widget build(BuildContext context) {
    final v = value;
    final score = v == null ? null : (v.clamp(0.0, 1.0) * 100).round();
    final animate = !MediaQuery.of(context).disableAnimations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              score?.toString() ?? '–',
              style: const TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w800,
                color: Color(0xFF4F39F6),
                fontFeatures: [FontFeature.tabularFigures()],
                height: 1,
              ),
            ),
            const SizedBox(width: 6),
            const Text('/ 100', style: TextStyle(fontSize: 13, color: _muted)),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              Container(
                height: 10,
                decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(5)),
              ),
              AnimatedContainer(
                duration: animate ? const Duration(milliseconds: 500) : Duration.zero,
                height: 10,
                width: c.maxWidth * ((score ?? 0) / 100),
                decoration: BoxDecoration(
                  color: score == null ? const Color(0xFFD1D5DC) : _colour(score),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          paused
              ? 'Paused by the headset: it stops scoring while it is off your head. '
                    'Focus resumes when you put it back on.'
              : score == null
              ? 'Focus appears once the headset sends its first score.'
              : 'Focus, computed by the headset',
          style: TextStyle(
            fontSize: 11,
            color: paused ? const Color(0xFFE17100) : _muted,
            fontWeight: paused ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
