import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../alpha_test.dart';
import '../band_power.dart';
import '../lsl_eeg_outlet.dart';
import 'saved_runs.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);
const _tabular = [FontFeature.tabularFigures()];

/// Colours for eyes open and eyes closed across the alpha views.
const alphaOpenColor = Color(0xFF5D80BD);
const alphaClosedColor = Color(0xFF7A5AC8);
const _alphaBand = Color(0x264F9A84);

/// Settings, start/stop, the current instruction and saved runs.
class AlphaControls extends StatelessWidget {
  const AlphaControls({super.key, required this.session, this.startBlockedReason});

  final AlphaSession session;
  final String? startBlockedReason;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final s = session.settings;
        final busy = session.busy;
        final blocked = !busy && startBlockedReason != null;
        final closed = session.eyesClosedNow;
        final endsAt = session.blockEndsAt;
        final left = endsAt == null ? null : math.max(0, endsAt - LslEegOutlet.localClock()).ceil();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Alternates eyes open and eyes closed, with spoken cues on the system output. Closing the eyes '
              'raises 8–13 Hz (alpha) power within seconds, so a clear rise means the headset is picking up '
              'brain activity.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 14),
            const Text('Blocks', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink)),
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
                  for (final n in const [4, 6, 8])
                    ButtonSegment(
                      value: n,
                      label: Text('$n each, ${(s.copyWith(blocksPerCondition: n).duration.inSeconds / 60).toStringAsFixed(1)} min'),
                    ),
                ],
                selected: {s.blocksPerCondition},
                onSelectionChanged: busy ? null : (v) => session.settings = s.copyWith(blocksPerCondition: v.first),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${s.blockSeconds.round()} s blocks; the first ${s.settleSeconds.round()} s after each cue are skipped. '
              'Fewer than ${AlphaSummary.minBlocks} of each cannot be tested.',
              style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 34,
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy ? session.stop : (blocked ? null : session.start),
                icon: Icon(busy ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 15),
                label: Text(
                  busy ? 'Stop test' : 'Start test',
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
            const SizedBox(height: 10),
            if (closed != null && session.state == AlphaState.running) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: (closed ? alphaClosedColor : alphaOpenColor).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      closed ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                      size: 18,
                      color: closed ? alphaClosedColor : alphaOpenColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        closed ? 'Eyes closed' : 'Eyes open',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: closed ? alphaClosedColor : alphaOpenColor,
                        ),
                      ),
                    ),
                    if (left != null)
                      Text(
                        '$left s',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _ink, fontFeatures: _tabular),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
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
            const SizedBox(height: 14),
            RunChecklist(
              folder: session.store?.directory.path,
              onClearAll: busy ? null : session.clearResults,
              items: [
                for (final r in session.runs)
                  RunItem(
                    started: r.started,
                    live: identical(r, session.current),
                    included: r.included,
                    onChanged: identical(r, session.current) ? null : (v) => session.setIncluded(r, v),
                    detail: _runDetail(r),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String _runDetail(AlphaRun r) {
    final open = r.blocks.where((b) => !b.eyesClosed).length;
    final closed = r.blocks.length - open;
    final s = AlphaSummary.compute(r.blocks, List.generate(12, (i) => i), binHz: r.binHz);
    return '$open open + $closed closed blocks'
        '${s.ratio == null ? '' : ' · alpha ×${s.ratio!.toStringAsFixed(2)}'}';
  }
}

/// Alpha power through the current (or newest) run, eyes-closed blocks
/// shaded, with each block's median as a bar: the numbers the test uses.
class AlphaTimeline extends StatelessWidget {
  const AlphaTimeline({super.key, required this.session, required this.channels});

  final AlphaSession session;
  final List<int> channels;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final run = session.shownRun;
        if (run == null || run.blocks.isEmpty) {
          return const Center(
            child: Text(
              'Alpha power appears here as the test runs.',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          );
        }
        return RepaintBoundary(
          child: CustomPaint(
            painter: _TimelinePainter(run, channels, live: identical(run, session.current)),
            size: Size.infinite,
          ),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.run, this.channels, {required this.live});

  final AlphaRun run;
  final List<int> channels;
  final bool live;

  double _value(List<double> alpha) =>
      math.log(math.max(1e-6, channels.fold(0.0, (s, c) => s + alpha[c]) / channels.length)) / math.ln10;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 46.0, bottom = 20.0, top = 8.0;
    final plot = Rect.fromLTRB(left, top, size.width - 4, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final t0 = run.blocks.first.cue;
    final planned = 2 * run.settings.blocksPerCondition * run.settings.blockSeconds;
    final span = math.max(planned, (run.timeline.lastOrNull?.$1 ?? t0) - t0);

    final points = [
      for (final (t, a) in run.timeline)
        if (t >= t0) (t - t0, _value(a)),
    ];
    var lo = points.isEmpty ? 0.0 : points.map((p) => p.$2).reduce(math.min);
    var hi = points.isEmpty ? 2.0 : points.map((p) => p.$2).reduce(math.max);
    lo = lo.floorToDouble();
    hi = math.max(hi.ceilToDouble(), lo + 1);
    double x(double t) => plot.left + plot.width * t / span;
    double y(double v) => plot.bottom - plot.height * (v - lo) / (hi - lo);
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(String s, Offset at, {bool right = false, bool center = false, Color color = _muted}) {
      label.text = TextSpan(text: s, style: TextStyle(fontSize: 10, color: color, fontFeatures: _tabular));
      label.layout();
      label.paint(canvas, at + Offset(right ? -label.width : (center ? -label.width / 2 : 0), -label.height / 2));
    }

    // Eyes-closed blocks.
    final now = live ? LslEegOutlet.localClock() : 0.0;
    for (final b in run.blocks) {
      final end = b.end ?? (live ? now : b.cue + run.settings.blockSeconds);
      if (b.eyesClosed) {
        canvas.drawRect(
          Rect.fromLTRB(x(b.cue - t0), plot.top, x(math.min(end - t0, span)), plot.bottom),
          Paint()..color = alphaClosedColor.withValues(alpha: 0.08),
        );
      }
    }

    // Grid: decades of µV² and every 30 s.
    final grid = Paint()..color = const Color(0xFFEEF0F3);
    for (var d = lo; d <= hi + 1e-9; d++) {
      canvas.drawLine(Offset(plot.left, y(d)), Offset(plot.right, y(d)), grid);
      text(_power(math.pow(10, d).toDouble()), Offset(plot.left - 6, y(d)), right: true);
    }
    text('µV²', Offset(plot.left - 6, plot.top - 2), right: true);
    for (var t = 0.0; t <= span + 1e-9; t += 30) {
      canvas.drawLine(Offset(x(t), plot.top), Offset(x(t), plot.bottom), grid);
      if (t % 60 == 0) text('${(t / 60).round()} min', Offset(x(t), plot.bottom + 10), center: true);
    }

    canvas.save();
    canvas.clipRect(plot);
    // Each window.
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(points[i].$1), y(points[i].$2));
      if (i == 0 || points[i].$1 - points[i - 1].$1 > 2) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF9AA1AD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    // Each block's median over its usable windows.
    for (final b in run.blocks) {
      if (b.windows < AlphaSummary.minWindows) continue;
      final values = [for (final a in b.windowAlpha) _value(a)]..sort();
      final m = values.length.isOdd
          ? values[values.length ~/ 2]
          : (values[values.length ~/ 2 - 1] + values[values.length ~/ 2]) / 2;
      final from = b.cue + run.settings.settleSeconds - t0;
      final to = (b.end ?? (live ? now : b.cue + run.settings.blockSeconds)) - t0;
      canvas.drawLine(
        Offset(x(from), y(m)),
        Offset(x(to), y(m)),
        Paint()
          ..color = b.eyesClosed ? alphaClosedColor : alphaOpenColor
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  static String _power(double v) => v >= 1 ? v.round().toString() : v.toStringAsFixed(v >= 0.1 ? 1 : 2);

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => true;
}

/// Mean spectrum with eyes open and closed, and the test of the difference.
class AlphaSpectrumPanel extends StatelessWidget {
  const AlphaSpectrumPanel({super.key, required this.session, required this.channels});

  final AlphaSession session;
  final List<int> channels;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final s = session.summary(channels);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _key(alphaOpenColor, 'Eyes open (${s.openBlocks} blocks)'),
                _key(alphaClosedColor, 'Eyes closed (${s.closedBlocks} blocks)'),
                const Text('Shaded: alpha, 8–13 Hz', style: TextStyle(fontSize: 11, color: _muted)),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: s.openSpectrum == null && s.closedSpectrum == null
                  ? const Center(
                      child: Text(
                        'Spectra appear after the first block (about 20 s).',
                        style: TextStyle(fontSize: 12, color: _muted),
                      ),
                    )
                  : RepaintBoundary(
                      child: CustomPaint(painter: _SpectrumPainter(s), size: Size.infinite),
                    ),
            ),
            const SizedBox(height: 10),
            _ResultTile(summary: s, finished: !session.busy),
          ],
        );
      },
    );
  }

  static Widget _key(Color color, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 14, height: 3, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 11, color: _ink, fontFeatures: _tabular)),
    ],
  );
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(this.s);

  final AlphaSummary s;
  static const _fMin = 1.0, _fMax = 30.0;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 46.0, bottom = 20.0, top = 6.0;
    final plot = Rect.fromLTRB(left, top, size.width - 4, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final values = <double>[
      for (final spec in [s.openSpectrum, s.closedSpectrum])
        if (spec != null)
          for (var k = 0; k < spec.length; k++)
            if (k * s.binHz >= _fMin && k * s.binHz <= _fMax && spec[k] > 0) math.log(spec[k]) / math.ln10,
    ];
    if (values.isEmpty) return;
    final lo = values.reduce(math.min).floorToDouble();
    final hi = math.max(values.reduce(math.max).ceilToDouble(), lo + 1);
    double x(double f) => plot.left + plot.width * (f - _fMin) / (_fMax - _fMin);
    double y(double v) => plot.bottom - plot.height * (v - lo) / (hi - lo);
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(String t, Offset at, {bool right = false, bool center = false}) {
      label.text = TextSpan(text: t, style: const TextStyle(fontSize: 10, color: _muted, fontFeatures: _tabular));
      label.layout();
      label.paint(canvas, at + Offset(right ? -label.width : (center ? -label.width / 2 : 0), -label.height / 2));
    }

    canvas.drawRect(
      Rect.fromLTRB(x(EegBand.alpha.low), plot.top, x(EegBand.alpha.high), plot.bottom),
      Paint()..color = _alphaBand,
    );
    final grid = Paint()..color = const Color(0xFFEEF0F3);
    for (var d = lo; d <= hi + 1e-9; d++) {
      canvas.drawLine(Offset(plot.left, y(d)), Offset(plot.right, y(d)), grid);
      final v = math.pow(10, d).toDouble();
      text(v >= 1 ? v.round().toString() : v.toStringAsFixed(v >= 0.1 ? 1 : 2), Offset(plot.left - 6, y(d)), right: true);
    }
    text('µV²/Hz', Offset(plot.left - 6, plot.top - 1), right: true);
    for (final f in const [1.0, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0]) {
      canvas.drawLine(Offset(x(f), plot.top), Offset(x(f), plot.bottom), grid);
      text('${f.round()}', Offset(x(f), plot.bottom + 10), center: true);
    }
    text('Hz', Offset(plot.right, plot.bottom + 10), right: true);

    canvas.save();
    canvas.clipRect(plot);
    for (final (spec, color) in [(s.openSpectrum, alphaOpenColor), (s.closedSpectrum, alphaClosedColor)]) {
      if (spec == null) continue;
      final path = Path();
      var started = false;
      for (var k = 0; k < spec.length; k++) {
        final f = k * s.binHz;
        if (f < _fMin || f > _fMax || spec[k] <= 0) continue;
        final o = Offset(x(f), y(math.log(spec[k]) / math.ln10));
        if (started) {
          path.lineTo(o.dx, o.dy);
        } else {
          path.moveTo(o.dx, o.dy);
          started = true;
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final peak = s.peakHz;
    if (peak != null && (s.ratio ?? 0) > 1) {
      canvas.drawLine(
        Offset(x(peak), plot.top),
        Offset(x(peak), plot.bottom),
        Paint()
          ..color = alphaClosedColor.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) => old.s != s;
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.summary, required this.finished});

  final AlphaSummary summary;
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final ratio = s.ratio;
    final p = s.p;
    final (verdict, fg, bg) = p == null
        ? ('Waiting', _muted, const Color(0xFFF1F2F5))
        : ratio! < 1 && p < 0.05
        ? ('Opposite', const Color(0xFFB42318), const Color(0xFFFDECEA))
        : p < 0.01
        ? ('Clear', const Color(0xFF0F7A3C), const Color(0xFFE8F8EF))
        : p < 0.05
        ? ('Likely', const Color(0xFF7A4B00), const Color(0xFFFFF7E6))
        : (finished ? 'Not found' : 'Not yet', _muted, const Color(0xFFF1F2F5));
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: _line)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Alpha with eyes closed vs open',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink),
                ),
                const SizedBox(height: 2),
                const Text(
                  '8–13 Hz power, median per block; permutation test across blocks',
                  style: TextStyle(fontSize: 10.5, color: _muted),
                ),
                const SizedBox(height: 6),
                Text(
                  ratio == null
                      ? 'Needs a block of each'
                      : '×${ratio.toStringAsFixed(2)}'
                            '${p == null ? '  ·  test after ${AlphaSummary.minBlocks} blocks of each' : '  ·  p = ${p.toStringAsFixed(p < 0.01 ? 4 : 3)}'}'
                            '${s.peakHz == null || ratio <= 1 ? '' : '  ·  largest rise at ${s.peakHz!.toStringAsFixed(1)} Hz'}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: ratio == null ? FontWeight.w400 : FontWeight.w700,
                    color: ratio == null ? _muted : _ink,
                    fontFeatures: _tabular,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Text(verdict, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg)),
          ),
        ],
      ),
    );
  }
}

/// Eyes closed ÷ eyes open alpha for each channel, in ear-cup order. Tap a bar
/// to show that channel above.
class AlphaChannelBars extends StatelessWidget {
  const AlphaChannelBars({super.key, required this.session, this.selected, required this.onSelected});

  final AlphaSession session;
  final int? selected;
  final ValueChanged<int> onSelected;

  /// Bars span ×0.5 to ×8 on a log scale.
  static const _minLog = -1.0, _maxLog = 3.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final summaries = [for (var c = 0; c < 12; c++) session.summary([c])];
        Widget bar(int c) {
          final s = summaries[c];
          final ratio = s.ratio;
          final log2 = ratio == null ? null : (math.log(ratio) / math.ln2).clamp(_minLog, _maxLog);
          final significant = (s.p ?? 1) < 0.05;
          final isSelected = selected == c;
          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => onSelected(c),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isSelected ? _ink : Colors.transparent, width: 1.5),
                ),
                child: Column(
                  children: [
                    Text(
                      ratio == null ? '–' : '×${ratio.toStringAsFixed(1)}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: significant ? FontWeight.w800 : FontWeight.w500,
                        color: significant ? _ink : _muted,
                        fontFeatures: _tabular,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) {
                          // ×1 sits a quarter of the way up.
                          final zero = box.maxHeight * (_maxLog / (_maxLog - _minLog));
                          final h = log2 == null ? 0.0 : box.maxHeight * (log2.abs() / (_maxLog - _minLog));
                          return Stack(
                            children: [
                              Positioned(
                                left: 0,
                                right: 0,
                                top: zero,
                                child: Container(height: 1, color: const Color(0xFFB8BDC7)),
                              ),
                              if (log2 != null)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  top: log2 >= 0 ? zero - h : zero,
                                  height: math.max(1, h),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: alphaClosedColor.withValues(alpha: significant ? 0.9 : 0.35),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Ch${c + 1}',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _ink),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Eyes closed ÷ open alpha; the line is ×1 (no change). Solid bars: p < 0.05 for that channel. '
              'Picking the best-looking channel after the fact overstates the evidence.',
              style: TextStyle(fontSize: 10.5, color: _muted),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < 6; c++) bar(c),
                  const SizedBox(width: 12),
                  for (var c = 6; c < 12; c++) bar(c),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Row(
              children: [
                Expanded(child: Center(child: Text('Left cup', style: TextStyle(fontSize: 10, color: _muted)))),
                SizedBox(width: 12),
                Expanded(child: Center(child: Text('Right cup', style: TextStyle(fontSize: 10, color: _muted)))),
              ],
            ),
          ],
        );
      },
    );
  }
}
