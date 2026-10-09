import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../erp.dart';
import '../oddball.dart';
import 'saved_runs.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);
const _tabular = [FontFeature.tabularFigures()];

/// Trace colours shared by the ERP plots and their legends.
const erpStandardColor = Color(0xFF5D80BD);
const erpRareColor = Color(0xFFE5484D);
const erpDifferenceColor = Color(0xFF111216);

/// Output, settings, start/stop and progress for an [OddballSession].
class OddballControls extends StatelessWidget {
  const OddballControls({super.key, required this.session, this.startBlockedReason});

  final OddballSession session;

  /// When non-null the start button is disabled and this explains why.
  final String? startBlockedReason;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final s = session.settings;
        final busy = session.busy;
        final blocked = !busy && startBlockedReason != null;
        final info = session.outputInfo;
        final bluetooth = busy && info != null ? info.bluetooth : (session.output?.bluetooth ?? _defaultIsBluetooth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Plays two tones, one of them rarely, and averages the EEG around each. A brain '
              'response to the rare tone (the P300) shows the headset is recording EEG.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 14),
            _label('Play tones through'),
            Row(
              children: [
                Expanded(child: _OutputPicker(session: session, enabled: !busy)),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Reload audio outputs',
                  child: IconButton.outlined(
                    onPressed: busy ? null : session.refreshOutputs,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      side: const BorderSide(color: _line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                    ),
                  ),
                ),
              ],
            ),
            if (bluetooth) ...[
              const SizedBox(height: 8),
              const _Notice(
                text:
                    'Bluetooth output: tones play from the speakers right beside the electrodes, the audio '
                    'link adds EEG data loss, and the timing relies on the latency macOS reports. The Mac\'s '
                    'own speakers give the cleanest test; through the headset, trust the rare-vs-standard '
                    'result over the response to every tone.',
              ),
            ],
            if (info != null) ...[
              const SizedBox(height: 6),
              Text(
                '${info.device}: macOS reports ${(info.latency * 1000).round()} ms output latency, '
                'which tone onsets include.',
                style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
              ),
            ],
            const SizedBox(height: 14),
            _label('Rare tone'),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                ),
                segments: [
                  ButtonSegment(value: true, label: Text('High, ${s.highHz.round()} Hz')),
                  ButtonSegment(value: false, label: Text('Low, ${s.lowHz.round()} Hz')),
                ],
                selected: {s.rareIsHigh},
                onSelectionChanged: busy ? null : (v) => session.settings = s.copyWith(rareIsHigh: v.first),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Results pool across runs. Do one run each way so pitch alone cannot explain a difference.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Dropdown<int>(
                    label: 'Tones per run',
                    value: s.trials,
                    enabled: !busy,
                    items: {
                      for (final n in const [100, 200, 300, 400])
                        n: '$n (~${(s.copyWith(trials: n).duration.inSeconds / 60).toStringAsFixed(0)} min)',
                    },
                    onChanged: (v) => session.settings = s.copyWith(trials: v),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Dropdown<int>(
                    label: 'Leave out above',
                    // 0 keeps every epoch.
                    value: session.rejectAbove?.round() ?? 0,
                    enabled: true,
                    items: const {75: '75 µV', 100: '100 µV', 150: '150 µV', 250: '250 µV', 0: 'Keep all'},
                    onChanged: (v) => session.rejectAbove = v == 0 ? null : v.toDouble(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                SizedBox(
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : session.preview,
                    icon: const Icon(Icons.volume_up_rounded, size: 15),
                    label: const Text('Preview', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _ink,
                      side: const BorderSide(color: _line),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 34,
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
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (session.state == OddballState.running && session.plannedTrials > 0) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: session.trialsPlayed / session.plannedTrials,
                  minHeight: 5,
                  backgroundColor: const Color(0xFFEDEEF1),
                  color: _ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tone ${session.trialsPlayed} of ${session.plannedTrials}',
                style: const TextStyle(fontSize: 11, color: _muted, fontFeatures: _tabular),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              blocked ? startBlockedReason! : session.statusText,
              style: TextStyle(
                fontSize: 12,
                color: session.state == OddballState.running ? _ink : _muted,
                fontWeight: session.state == OddballState.running ? FontWeight.w600 : FontWeight.w400,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Text(_resultsLine(session), style: const TextStyle(fontSize: 11, color: _muted, height: 1.35)),
            const SizedBox(height: 12),
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
                    detail:
                        '${r.trialsPlayed} tones, rare ${r.settings.rareIsHigh ? 'high' : 'low'} '
                        '(${r.settings.rareHz.round()} Hz) · ${r.output ?? 'unknown output'}',
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  bool get _defaultIsBluetooth => session.outputs.where((d) => d.isDefault).firstOrNull?.bluetooth ?? false;

  static String _resultsLine(OddballSession s) {
    final rare = s.epochs.where((e) => e.event.rare).length;
    final standard = s.epochs.length - rare;
    final lost = s.rejections.values.fold(0, (a, b) => a + b);
    if (s.epochs.isEmpty && lost == 0) return 'No responses in the results yet.';
    final parts = ['$standard standard and $rare rare responses'];
    if (lost > 0) {
      parts.add(
        '$lost unusable (${[for (final e in s.rejections.entries) '${e.value} ${e.key.label}'].join(', ')})',
      );
    }
    return parts.join('; ');
  }

  static Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink)),
  );
}

/// The average response for [channels]: standard and rare traces with ±1 SE
/// bands, their difference, and the two tests.
class ErpPanel extends StatelessWidget {
  const ErpPanel({super.key, required this.session, required this.channels});

  final OddballSession session;
  final List<int> channels;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final summary = session.summary(channels);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Legend(summary: summary),
            const SizedBox(height: 8),
            Expanded(child: ErpPlot(summary: summary)),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _TestTile(
                    title: 'Response to every tone',
                    detail: 'Mean 80–150 ms after onset (auditory N1) vs zero',
                    test: summary.response,
                    needs: 'Needs ${ErpSummary.minTrials} responses',
                    finished: !session.busy,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TestTile(
                    title: 'Rare vs standard',
                    detail: 'Rare minus standard, 250–500 ms (P300)',
                    test: summary.oddball,
                    needs: 'Needs ${ErpSummary.minRare} rare and ${ErpSummary.minRare} standard',
                    finished: !session.busy,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Small plots of every channel in ear-cup order; tap one to select it.
class ErpChannelGrid extends StatelessWidget {
  const ErpChannelGrid({super.key, required this.session, this.selected, required this.onSelected});

  final OddballSession session;

  /// Highlighted channel (0-based), if the main plot shows a single channel.
  final int? selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final summaries = [for (var c = 0; c < 12; c++) session.summary([c], tests: false)];
        // One scale for every tile, so sizes compare across channels.
        final range = ErpPlot.niceRange(summaries.fold(0.0, (m, s) => math.max(m, s.peak)));
        Widget tile(int c) {
          final s = summaries[c];
          final diff = s.difference;
          final effect = diff == null ? null : ErpSummary.windowMean(diff, ErpSummary.oddballWindow);
          final isSelected = selected == c;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(color: isSelected ? _ink : _line, width: isSelected ? 1.5 : 1),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onSelected(c),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // On narrow tiles the number is clipped rather than
                        // overflowing.
                        Row(
                          children: [
                            Text('Ch${c + 1}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _ink)),
                            if (effect != null)
                              Expanded(
                                child: Text(
                                  '${effect >= 0 ? '+' : '−'}${effect.abs().toStringAsFixed(1)}',
                                  textAlign: TextAlign.right,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.clip,
                                  style: const TextStyle(fontSize: 9.5, color: _muted, fontFeatures: _tabular),
                                ),
                              ),
                          ],
                        ),
                        Expanded(child: ErpPlot(summary: s, range: range, compact: true)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        Widget row(String side, List<int> channels) => Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(side, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _muted)),
              ),
              for (final c in channels) tile(c),
            ],
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Same scale, ±${_scale(range)} µV. Number: rare minus standard, 250–500 ms. '
              'Picking the best-looking channel after the fact overstates the evidence.',
              style: const TextStyle(fontSize: 10.5, color: _muted),
            ),
            const SizedBox(height: 6),
            row('Left', const [0, 1, 2, 3, 4, 5]),
            row('Right', const [6, 7, 8, 9, 10, 11]),
          ],
        );
      },
    );
  }
}

/// Standard and rare averages (with ±1 SE bands in the full size), their
/// difference, onset at 0 and the test windows shaded. Positive is up.
class ErpPlot extends StatelessWidget {
  const ErpPlot({super.key, required this.summary, this.range, this.compact = false});

  final ErpSummary summary;

  /// Half-height in µV; chosen from the data when null.
  final double? range;
  final bool compact;

  static const _ranges = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0];

  /// A round half-height that fits [peak] µV, at least 2 µV.
  static double niceRange(double peak) => _ranges.firstWhere((r) => r >= peak && r >= 2, orElse: () => 1000);

  @override
  Widget build(BuildContext context) {
    if (!compact && summary.isEmpty) {
      return const Center(
        child: Text(
          'The average appears once the first tones have played\n(each response is ready about 2 s after its tone).',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: _muted, height: 1.4),
        ),
      );
    }
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ErpPainter(summary, range: range ?? niceRange(summary.peak), compact: compact),
        size: Size.infinite,
      ),
    );
  }
}

class _ErpPainter extends CustomPainter {
  _ErpPainter(this.summary, {required this.range, required this.compact});

  final ErpSummary summary;
  final double range;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final left = compact ? 0.0 : 44.0;
    final bottom = compact ? 0.0 : 20.0;
    final top = compact ? 2.0 : 16.0;
    final plot = Rect.fromLTRB(left, top, size.width, size.height - bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    double x(double t) => plot.left + plot.width * (t - ErpEpoch.start) / (ErpEpoch.end - ErpEpoch.start);
    double y(double v) => plot.center.dy - v / range * plot.height / 2;
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(String s, Offset at, {Color color = _muted, double fontSize = 10, bool right = false, bool center = false}) {
      label.text = TextSpan(text: s, style: TextStyle(fontSize: fontSize, color: color, fontFeatures: _tabular));
      label.layout();
      final dx = right ? -label.width : (center ? -label.width / 2 : 0.0);
      label.paint(canvas, at + Offset(dx, -label.height / 2));
    }

    // Test windows.
    if (!compact) {
      for (final (window, name, color) in [
        (ErpSummary.responseWindow, 'N1', const Color(0x145D80BD)),
        (ErpSummary.oddballWindow, 'P300', const Color(0x1FE5C100)),
      ]) {
        canvas.drawRect(Rect.fromLTRB(x(window.$1), plot.top, x(window.$2), plot.bottom), Paint()..color = color);
        text(name, Offset((x(window.$1) + x(window.$2)) / 2, plot.top - 8), center: true, fontSize: 9.5);
      }
    }

    // Grid.
    final grid = Paint()
      ..color = const Color(0xFFEEF0F3)
      ..strokeWidth = 1;
    if (!compact) {
      for (var ms = -200; ms <= 800; ms += 100) {
        canvas.drawLine(Offset(x(ms / 1000), plot.top), Offset(x(ms / 1000), plot.bottom), grid);
        if (ms % 200 == 0) text(ms == 0 ? '0' : '$ms', Offset(x(ms / 1000), plot.bottom + 10), center: true);
      }
      text('ms', Offset(plot.right, plot.bottom + 10), right: true);
      for (final v in [range, range / 2, -range / 2, -range]) {
        canvas.drawLine(Offset(plot.left, y(v)), Offset(plot.right, y(v)), grid);
        text('${v > 0 ? '+' : '−'}${_scale(v.abs())}', Offset(plot.left - 6, y(v)), right: true);
      }
      text('µV', Offset(plot.left - 6, plot.top - 8), right: true);
    }
    final axis = Paint()
      ..color = const Color(0xFFB8BDC7)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(plot.left, y(0)), Offset(plot.right, y(0)), axis);
    canvas.drawLine(Offset(x(0), plot.top), Offset(x(0), plot.bottom), axis..color = const Color(0xFF8A909B));

    canvas.save();
    canvas.clipRect(plot);
    void band(List<double> mean, List<double> se, Color color) {
      final path = Path()..moveTo(x(ErpEpoch.timeAt(0)), y(mean[0] + se[0]));
      for (var i = 1; i < ErpEpoch.length; i++) {
        path.lineTo(x(ErpEpoch.timeAt(i)), y(mean[i] + se[i]));
      }
      for (var i = ErpEpoch.length - 1; i >= 0; i--) {
        path.lineTo(x(ErpEpoch.timeAt(i)), y(mean[i] - se[i]));
      }
      canvas.drawPath(path..close(), Paint()..color = color.withValues(alpha: 0.14));
    }

    void trace(List<double> values, Color color, double width) {
      final path = Path()..moveTo(x(ErpEpoch.timeAt(0)), y(values[0]));
      for (var i = 1; i < ErpEpoch.length; i++) {
        path.lineTo(x(ErpEpoch.timeAt(i)), y(values[i]));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round,
      );
    }

    final s = summary;
    if (!compact) {
      if (s.standardCount > 1) band(s.standardMean, s.standardSe, erpStandardColor);
      if (s.rareCount > 1) band(s.rareMean, s.rareSe, erpRareColor);
    }
    if (s.standardCount > 0) trace(s.standardMean, erpStandardColor, compact ? 1 : 1.6);
    if (s.rareCount > 0) trace(s.rareMean, erpRareColor, compact ? 1 : 1.6);
    final diff = s.difference;
    if (diff != null && !compact) trace(diff, erpDifferenceColor, 1.2);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ErpPainter old) =>
      old.summary != summary || old.range != range || old.compact != compact;
}

String _scale(double v) => v >= 10 || v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _Legend extends StatelessWidget {
  const _Legend({required this.summary});

  final ErpSummary summary;

  @override
  Widget build(BuildContext context) {
    Widget key(Color color, String text) => Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 14, height: 3, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 11, color: _ink, fontFeatures: _tabular)),
        ],
      ),
    );
    return Wrap(
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        key(erpStandardColor, 'Standard (${summary.standardCount})'),
        key(erpRareColor, 'Rare (${summary.rareCount})'),
        key(erpDifferenceColor, 'Rare − standard'),
        Text(
          summary.artifactCount > 0
              ? '${summary.artifactCount} left out as artifacts · shading ±1 SE · positive up'
              : 'Shading ±1 SE · positive up',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      ],
    );
  }
}

class _TestTile extends StatelessWidget {
  const _TestTile({
    required this.title,
    required this.detail,
    required this.test,
    required this.needs,
    required this.finished,
  });

  final String title;
  final String detail;
  final WindowTest? test;
  final String needs;

  /// No run is going, so "not significant" is the answer rather than "not yet".
  final bool finished;

  @override
  Widget build(BuildContext context) {
    final t = test;
    final p = t?.p;
    final (verdict, fg, bg) = p == null
        ? ('Waiting', _muted, const Color(0xFFF1F2F5))
        : p < 0.01
        ? ('Clear', const Color(0xFF0F7A3C), const Color(0xFFE8F8EF))
        : p < 0.05
        ? ('Likely', const Color(0xFF7A4B00), const Color(0xFFFFF7E6))
        : (finished ? 'Not found' : 'Not yet', _muted, const Color(0xFFF1F2F5));
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: _line)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
                child: Text(verdict, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: fg)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(detail, style: const TextStyle(fontSize: 10.5, color: _muted)),
          const SizedBox(height: 6),
          Text(
            t == null
                ? needs
                : '${t.effect >= 0 ? '+' : '−'}${t.effect.abs().toStringAsFixed(2)} µV  ·  '
                      'p ${t.atFloor ? '< ${(1 / t.permutations).toStringAsFixed(4)}' : '= ${t.p.toStringAsFixed(3)}'}'
                      '  ·  ${t.trials} responses',
            style: TextStyle(
              fontSize: 12,
              fontWeight: t == null ? FontWeight.w400 : FontWeight.w700,
              color: t == null ? _muted : _ink,
              fontFeatures: _tabular,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutputPicker extends StatelessWidget {
  const _OutputPicker({required this.session, required this.enabled});

  final OddballSession session;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final outputs = session.outputs;
    final system = outputs.where((d) => d.isDefault).firstOrNull;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: enabled ? Colors.white : const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: _line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          isExpanded: true,
          // -1 is the system output.
          value: session.output?.id ?? -1,
          style: const TextStyle(fontSize: 12, color: _ink),
          items: [
            DropdownMenuItem(
              value: -1,
              child: Text(
                system == null ? 'System output' : 'System output (${system.name})',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final d in outputs)
              DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: enabled
              ? (id) => session.output = outputs.where((d) => d.id == id).firstOrNull
              : null,
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.enabled,
  });

  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink)),
      const SizedBox(height: 6),
      Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: enabled ? Colors.white : const Color(0xFFF7F7F8),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: _line),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            isExpanded: true,
            value: value,
            style: const TextStyle(fontSize: 12, color: _ink),
            items: [
              for (final e in items.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: enabled
                ? (v) {
                    if (v != null) onChanged(v);
                  }
                : null,
          ),
        ),
      ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF7E6),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0xFFF3D9A4)),
    ),
    child: Text(text, style: const TextStyle(fontSize: 11, color: Color(0xFF7A4B00), height: 1.35)),
  );
}
