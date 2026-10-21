import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../focus_metric.dart';
import '../focus_session.dart';
import '../lsl_eeg_outlet.dart';
import 'focus_visuals.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);
const _tabular = [FontFeature.tabularFigures()];
const _scoreColor = Color(0xFF4F39F6);
const _restColor = Color(0xFF5D80BD);

/// Calibration controls, model quality and what drives the score.
class FocusControls extends StatelessWidget {
  const FocusControls({super.key, required this.session, this.startBlockedReason});

  final FocusSession session;
  final String? startBlockedReason;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final s = session.settings;
        final busy = session.calibrating;
        final blocked = !busy && startBlockedReason != null;
        final model = session.model;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your own focus score, computed in this app from the raw EEG. A short calibration alternates '
              'relaxing with counting backwards in sevens; the score then shows how closely your EEG matches '
              'your focused blocks.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 14),
            const Text(
              'Calibration',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                ),
                segments: [
                  for (final n in const [3, 4, 6])
                    ButtonSegment(
                      value: n,
                      label: Text('$n each, ${s.copyWith(blocksPerCondition: n).duration.inMinutes} min'),
                    ),
                ],
                selected: {s.blocksPerCondition},
                onSelectionChanged: busy ? null : (v) => session.settings = s.copyWith(blocksPerCondition: v.first),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${s.blockSeconds.round()} s blocks with spoken cues. Keep your jaw relaxed and your eyes on the dot '
              'throughout; counting is silent.',
              style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 34,
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy ? session.stop : (blocked ? null : session.calibrate),
                icon: Icon(busy ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 15),
                label: Text(
                  busy ? 'Stop calibration' : (model == null ? 'Calibrate' : 'Recalibrate'),
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
            if (busy && session.blockNumber > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: session.blockNumber / session.blockCount,
                  minHeight: 5,
                  backgroundColor: const Color(0xFFEDEEF1),
                  color: _ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Block ${session.blockNumber} of ${session.blockCount}',
                style: const TextStyle(fontSize: 11, color: _muted, fontFeatures: _tabular),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              blocked ? startBlockedReason! : session.statusText,
              style: const TextStyle(fontSize: 12, color: _muted, height: 1.35),
            ),
            if (model != null) ...[const SizedBox(height: 14), _ModelSummary(model: model)],
            const SizedBox(height: 14),
            const Text(
              'Published to LSL as "${FocusSession.lslName}": focus (0–100) and quality (1 clean, 0 too noisy), '
              'about twice a second.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
          ],
        );
      },
    );
  }
}

class _ModelSummary extends StatelessWidget {
  const _ModelSummary({required this.model});

  final FocusModel model;

  @override
  Widget build(BuildContext context) {
    final auc = model.cvAuc;
    final (verdict, fg, bg) = auc >= 0.75
        ? ('Good', const Color(0xFF0F7A3C), const Color(0xFFE8F8EF))
        : auc >= FocusSession.minUsefulAuc
        ? ('Fair', const Color(0xFF7A4B00), const Color(0xFFFFF7E6))
        : ('Unreliable', const Color(0xFFB42318), const Color(0xFFFDECEA));
    final created = model.created;
    String two(int v) => v.toString().padLeft(2, '0');
    final drivers = model.drivers().take(3).toList();
    final strongest = drivers.isEmpty ? 1.0 : drivers.first.$2.abs();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Your calibration',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  verdict,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${created.year}-${two(created.month)}-${two(created.day)} ${two(created.hour)}:${two(created.minute)} · '
            '${model.blocksUsed.$1} focus + ${model.blocksUsed.$2} rest blocks used'
            '${model.blocksLeftOut > 0 ? ', ${model.blocksLeftOut} left out' : ''}',
            style: const TextStyle(fontSize: 10.5, color: _muted),
          ),
          const SizedBox(height: 6),
          Text(
            '${(model.cvAccuracy * 100).round()}% correct on held-out blocks · AUC ${auc.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink, fontFeatures: _tabular),
          ),
          if (auc < FocusSession.minUsefulAuc)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Focus and rest looked too similar to score reliably. Check the fit, keep still, and recalibrate.',
                style: TextStyle(fontSize: 11, color: Color(0xFFB42318), height: 1.35),
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            'What drives your score',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _ink),
          ),
          const SizedBox(height: 4),
          for (final (name, weight) in drivers)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 6,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: (weight.abs() / strongest).clamp(0.05, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: weight > 0 ? _scoreColor : _restColor,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${name[0].toUpperCase()}${name.substring(1)}: ${weight > 0 ? 'larger' : 'smaller'} share when focused',
                      style: const TextStyle(fontSize: 11, color: _ink),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The live score as an animation beside the number and bar, or the
/// calibration instruction with a fixation dot.
///
/// The animation is hidden during calibration, so focus and rest blocks look
/// the same apart from the instruction.
class FocusScoreView extends StatelessWidget {
  const FocusScoreView({super.key, required this.session, this.visual = FocusVisual.flame});

  final FocusSession session;
  final FocusVisual visual;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        if (session.calibrating) return _CalibrationPrompt(session: session);
        if (session.model == null) {
          return const Center(
            child: Text('Calibrate to start scoring.', style: TextStyle(fontSize: 13, color: _muted)),
          );
        }
        final score = session.score;
        final picture = FocusVisualView(
          visual: visual,
          level: score == null ? null : score / 100,
          target: session.target / 100,
          paused: session.noisy,
          climbSeconds: session.secondsAboveTarget,
        );
        final readout = _ScoreReadout(session: session);
        return LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 560
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: picture),
                    const SizedBox(width: 20),
                    Expanded(flex: 4, child: readout),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: picture),
                    const SizedBox(height: 12),
                    readout,
                  ],
                ),
        );
      },
    );
  }
}

class _ScoreReadout extends StatelessWidget {
  const _ScoreReadout({required this.session});

  final FocusSession session;

  static String _duration(double seconds) {
    final s = seconds.round();
    return s < 60 ? '$s s' : '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
  }

  @override
  Widget build(BuildContext context) {
    final score = session.score;
    final reason = session.noisyReason;
    if (score == null) {
      if (!session.noisy) {
        return const Center(
          child: Text(
            'The score appears a few seconds after raw EEG starts streaming.',
            style: TextStyle(fontSize: 13, color: _muted),
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'No clean EEG to score yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF7A4B00)),
          ),
          const SizedBox(height: 8),
          if (reason != null) Text(reason, style: const TextStyle(fontSize: 12, color: _ink, height: 1.4)),
          const SizedBox(height: 10),
          const Text(
            'Seat both cups fully over your ears with hair out from under the pads, keep still with your jaw '
            'relaxed, and keep the Mac close. The Live signals tab shows contact per channel.',
            style: TextStyle(fontSize: 11, color: _muted, height: 1.4),
          ),
        ],
      );
    }
    final animate = !MediaQuery.of(context).disableAnimations;
    final target = session.target;
    final above = session.aboveTarget;
    final scored = session.scoredSeconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              score.round().toString(),
              style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800, color: _scoreColor, height: 1),
            ),
            const SizedBox(width: 8),
            const Text('/ 100', style: TextStyle(fontSize: 16, color: _muted)),
          ],
        ),
        const SizedBox(height: 8),
        if (session.noisy)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: const Color(0xFFFFF7E6), borderRadius: BorderRadius.circular(10)),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFF7A4B00)),
                SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Too noisy to score: holding the last value',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF7A4B00)),
                  ),
                ),
              ],
            ),
          )
        else
          Text(
            above ? 'At or above your target' : 'Below your target',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: above ? _scoreColor : _muted),
          ),
        if (reason != null) ...[
          const SizedBox(height: 4),
          Text(reason, style: const TextStyle(fontSize: 11, color: Color(0xFF7A4B00), height: 1.35)),
        ],
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, c) => SizedBox(
            height: 18,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 3,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(color: const Color(0xFFEDEEF1), borderRadius: BorderRadius.circular(6)),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 3,
                  child: AnimatedContainer(
                    duration: animate ? const Duration(milliseconds: 400) : Duration.zero,
                    height: 12,
                    width: c.maxWidth * (score / 100).clamp(0.0, 1.0),
                    decoration: BoxDecoration(color: _scoreColor, borderRadius: BorderRadius.circular(6)),
                  ),
                ),
                // The target, as a tick across the bar.
                Positioned(
                  left: (c.maxWidth * target / 100 - 1.5).clamp(0.0, c.maxWidth - 3),
                  top: 0,
                  child: Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(color: _ink, borderRadius: BorderRadius.circular(1.5)),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '0 = like your resting blocks, 100 = like your focused blocks. Smoothed over about 4 s.',
          style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
        ),
        const SizedBox(height: 6),
        Text(
          'Target ${target.round()} (the tick): your ${(FocusSession.targetPercentile * 100).round()}th percentile '
          'over the last ${(FocusSession.targetSpan / 60).round()} min, updated every minute.',
          style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
        ),
        if (scored >= 10) ...[
          const SizedBox(height: 6),
          Text(
            'At or above target ${(100 * session.secondsAboveTarget / scored).round()}% of the time '
            '(${_duration(session.secondsAboveTarget)} of ${_duration(scored)})',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _ink, fontFeatures: _tabular),
          ),
        ],
      ],
    );
  }
}

class _CalibrationPrompt extends StatelessWidget {
  const _CalibrationPrompt({required this.session});

  final FocusSession session;

  @override
  Widget build(BuildContext context) {
    final focus = session.focusBlockNow;
    final endsAt = session.blockEndsAt;
    final left = endsAt == null ? null : math.max(0, endsAt - LslEegOutlet.localClock()).ceil();
    final (title, detail) = switch (focus) {
      true => ('Count backwards from ${session.countFrom} in sevens', 'Silently, eyes on the dot, jaw relaxed.'),
      false => ('Relax', 'Let your mind wander. Eyes on the dot.'),
      null => ('Get ready', 'Sit comfortably and look at the dot.'),
    };
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: focus == true ? _scoreColor : _ink),
        ),
        const SizedBox(height: 6),
        Text(detail, style: const TextStyle(fontSize: 13, color: _muted)),
        const SizedBox(height: 24),
        Container(
          width: 14,
          height: 14,
          decoration: const BoxDecoration(color: _ink, shape: BoxShape.circle),
        ),
        const SizedBox(height: 24),
        if (left != null)
          Text(
            '$left s',
            style: const TextStyle(fontSize: 13, color: _muted, fontFeatures: _tabular),
          ),
      ],
    );
  }
}

/// The score over the last few minutes; gaps mark windows too noisy to score.
class FocusTimeline extends StatelessWidget {
  const FocusTimeline({super.key, required this.session, this.minutes = 5});

  final FocusSession session;
  final double minutes;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (session.history.isEmpty) {
          return const Center(
            child: Text('The score over time appears here.', style: TextStyle(fontSize: 12, color: _muted)),
          );
        }
        return RepaintBoundary(
          child: CustomPaint(painter: _TimelinePainter(List.of(session.history), minutes * 60), size: Size.infinite),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.points, this.span);

  final List<FocusPoint> points;
  final double span;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, bottom = 18.0, top = 6.0;
    final plot = Rect.fromLTRB(left, top, size.width - 6, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final end = points.last.time;
    double x(double t) => plot.right - plot.width * (end - t) / span;
    double y(double v) => plot.bottom - plot.height * v / 100;
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(String s, Offset at, {bool right = false, bool center = false}) {
      label.text = TextSpan(
        text: s,
        style: const TextStyle(fontSize: 10, color: _muted, fontFeatures: _tabular),
      );
      label.layout();
      label.paint(canvas, at + Offset(right ? -label.width : (center ? -label.width / 2 : 0), -label.height / 2));
    }

    final grid = Paint()..color = const Color(0xFFEEF0F3);
    for (final v in const [0.0, 25.0, 50.0, 75.0, 100.0]) {
      canvas.drawLine(Offset(plot.left, y(v)), Offset(plot.right, y(v)), grid);
      text(v.round().toString(), Offset(plot.left - 6, y(v)), right: true);
    }
    for (var m = 0.0; m <= span / 60 + 1e-9; m += 1) {
      final px = x(end - m * 60);
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), grid);
      text(m == 0 ? 'now' : '−${m.round()} min', Offset(px, plot.bottom + 9), center: m > 0, right: m == 0);
    }

    canvas.save();
    canvas.clipRect(plot);
    // Noisy stretches, shaded.
    final noisyPaint = Paint()..color = const Color(0x1AB42318);
    for (var i = 0; i < points.length; i++) {
      if (!points[i].noisy) continue;
      final next = i + 1 < points.length ? points[i + 1].time : points[i].time + 0.5;
      canvas.drawRect(Rect.fromLTRB(x(points[i].time), plot.top, x(next), plot.bottom), noisyPaint);
    }
    // The target, as a dashed step line.
    final targetPaint = Paint()
      ..color = _ink.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (var i = 0; i < points.length; i++) {
      final t = points[i].target;
      if (t == null) continue;
      final from = x(points[i].time);
      final to = i + 1 < points.length ? x(points[i + 1].time) : from;
      for (var px = from; px < to; px += 2) {
        if ((px / 4).floor().isEven) canvas.drawLine(Offset(px, y(t)), Offset(math.min(px + 2, to), y(t)), targetPaint);
      }
    }
    final path = Path();
    var drawing = false;
    for (final p in points) {
      final s = p.score;
      if (s == null) {
        drawing = false;
        continue;
      }
      final o = Offset(x(p.time), y(s));
      if (drawing) {
        path.lineTo(o.dx, o.dy);
      } else {
        path.moveTo(o.dx, o.dy);
        drawing = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _scoreColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => true;
}
