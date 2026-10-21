import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../erp.dart';
import '../oddball.dart';
import '../sound_calibration.dart';
import 'number_field.dart';
import 'saved_runs.dart';
import 'sound_calibration_dialog.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);
const _tabular = [FontFeature.tabularFigures()];

/// Trace colours shared by the ERP plots and their legends.
const erpStandardColor = Color(0xFF5D80BD);
const erpRareColor = Color(0xFFE5484D);
const erpDifferenceColor = Color(0xFF111216);

/// Output, sound level, settings, start/stop and progress for an
/// [OddballSession].
class OddballControls extends StatefulWidget {
  const OddballControls({super.key, required this.session, this.startBlockedReason});

  final OddballSession session;

  /// When non-null the start button is disabled and this explains why.
  final String? startBlockedReason;

  @override
  State<OddballControls> createState() => _OddballControlsState();
}

class _OddballControlsState extends State<OddballControls> {
  /// Notices a change of Mac volume, which would put a calibrated level off.
  Timer? _volumePoll;

  OddballSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    _volumePoll = Timer.periodic(const Duration(seconds: 2), (_) => session.refreshVolume());
  }

  @override
  void dispose() {
    _volumePoll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final s = session.settings;
        final busy = session.busy;
        final levelProblem = session.levelProblem;
        final blockedReason = widget.startBlockedReason ?? (levelProblem == null ? null : 'Fix the sound level to start.');
        final blocked = !busy && blockedReason != null;
        final info = session.outputInfo;
        final bluetooth = busy && info != null ? info.bluetooth : (session.output?.bluetooth ?? _defaultIsBluetooth);
        void set(OddballSettings value) => session.settings = value;
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
                Expanded(
                  child: _OutputPicker(session: session, enabled: !busy),
                ),
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
            _SoundLevel(session: session),
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
                onSelectionChanged: busy ? null : (v) => set(s.copyWith(rareIsHigh: v.first)),
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
                    label: 'Rare (deviant) share',
                    // Percent, so the keys compare exactly.
                    value: (s.rareProbability * 100).round(),
                    enabled: !busy,
                    items: {
                      for (final p in OddballSettings.rareOptions)
                        (p * 100).round(): '${(p * 100).round()}% (1 in ${_oneIn(p)})',
                    },
                    onChanged: (v) => set(s.copyWith(rareProbability: v / 100)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Dropdown<int>(
                    label: 'Tone length',
                    value: (s.toneSeconds * 1000).round(),
                    enabled: !busy,
                    items: {for (final t in OddballSettings.toneOptions) (t * 1000).round(): '${(t * 1000).round()} ms'},
                    onChanged: (v) => set(s.copyWith(toneSeconds: v / 1000)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _label('Time between tones (ISI)'),
            Row(
              children: [
                Expanded(
                  child: _Captioned(
                    caption: 'Shortest',
                    child: NumberStepper(
                      value: s.minInterval,
                      min: OddballSettings.shortestInterval,
                      max: OddballSettings.longestInterval,
                      step: 0.05,
                      decimals: 2,
                      unit: 's',
                      enabled: !busy,
                      onChanged: (v) => set(s.copyWith(minInterval: v, maxInterval: math.max(v, s.maxInterval))),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Captioned(
                    caption: 'Longest',
                    child: NumberStepper(
                      value: s.maxInterval,
                      min: OddballSettings.shortestInterval,
                      max: OddballSettings.longestInterval,
                      step: 0.05,
                      decimals: 2,
                      unit: 's',
                      enabled: !busy,
                      onChanged: (v) => set(s.copyWith(maxInterval: v, minInterval: math.min(v, s.minInterval))),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s.minInterval == s.maxInterval
                  ? 'Onset to onset, every ${NumberStepper.format(s.minInterval, 2)} s. Make them differ to '
                        'vary the gap so the next tone cannot be predicted.'
                  : 'Onset to onset. Each gap is drawn at random between the two, so the next tone cannot '
                        'be predicted.',
              style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            if (s.minInterval < ErpEpoch.end) ...[
              const SizedBox(height: 6),
              _Notice(
                text:
                    'Under ${(ErpEpoch.end * 1000).round()} ms, the next tone starts before the response to '
                    'this one has been averaged (the plot runs to ${(ErpEpoch.end * 1000).round()} ms), so '
                    'responses overlap and the late part of the average mixes both.',
              ),
            ],
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
                        n: '$n (~${_minutes(s.copyWith(trials: n).duration)} min)',
                    },
                    onChanged: (v) => set(s.copyWith(trials: v)),
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
            const SizedBox(height: 10),
            _Dropdown<int>(
              label: 'High-pass for the responses',
              // Tenths of a hertz, so the keys compare exactly.
              value: (s.highPassHz * 10).round(),
              enabled: !busy,
              items: {
                for (final hz in OddballSettings.highPassOptions)
                  (hz * 10).round(): hz == 0.5
                      ? '0.5 Hz (keeps more of the slow P300)'
                      : '1 Hz (dry-electrode convention)',
              },
              onChanged: (v) => set(s.copyWith(highPassHz: v / 10)),
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
              blocked ? blockedReason : session.statusText,
              style: TextStyle(
                fontSize: 12,
                color: session.state == OddballState.running ? _ink : _muted,
                fontWeight: session.state == OddballState.running ? FontWeight.w600 : FontWeight.w400,
                height: 1.35,
              ),
            ),
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
                    detail: _runDetail(r),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  bool get _defaultIsBluetooth => session.outputs.where((d) => d.isDefault).firstOrNull?.bluetooth ?? false;

  static String _oneIn(double p) {
    final n = 1 / p;
    return n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(1);
  }

  static String _minutes(Duration d) => (d.inSeconds / 60).toStringAsFixed(0);

  static String _runDetail(OddballRun r) {
    final s = r.settings;
    return '${r.trialsPlayed} tones, rare ${s.rareIsHigh ? 'high' : 'low'} (${s.rareHz.round()} Hz, '
        '${(s.rareProbability * 100).round()}%) · ${r.levelLabel} · ${(s.toneSeconds * 1000).round()} ms tones, '
        'ISI ${NumberStepper.format(s.minInterval, 2)}–${NumberStepper.format(s.maxInterval, 2)} s · '
        '${r.output ?? 'unknown output'}'
        '${s.highPassHz == 0.5 ? '' : ' · ${s.highPassHz} Hz high-pass'}';
  }
}

Widget _label(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    text,
    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
  ),
);

/// The tones' level: in dB SPL once the output is calibrated, otherwise
/// relative to the loudest the app plays, with the calibration a click away.
class _SoundLevel extends StatelessWidget {
  const _SoundLevel({required this.session});

  final OddballSession session;

  @override
  Widget build(BuildContext context) {
    final s = session.settings;
    final busy = session.busy;
    final c = session.calibration;
    final volume = session.volume;
    final name = session.outputName ?? 'this output';
    void set(OddballSettings value) => session.settings = value;
    final children = <Widget>[
      Row(
        children: [
          const Expanded(
            child: Text(
              'Sound level',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
            ),
          ),
          SizedBox(
            height: 26,
            child: TextButton.icon(
              // Calibrations are kept by output name.
              onPressed: busy || session.outputName == null ? null : () => showSoundCalibration(context, session),
              icon: const Icon(Icons.tune_rounded, size: 14),
              label: Text(
                c == null ? 'Calibrate…' : 'Calibration…',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
    ];
    if (c == null) {
      children.addAll([
        NumberStepper(
          value: s.levelDbfs,
          min: OddballSettings.minDbfs,
          max: 0,
          step: 1,
          unit: 'dB',
          enabled: !busy,
          onChanged: (v) => set(s.copyWith(levelDbfs: v)),
        ),
        const SizedBox(height: 6),
        _Notice(
          text:
              '$name is not calibrated, so this level is relative: 0 dB is the loudest the app plays, and '
              'the Mac volume${volume == null ? '' : ' (now ${OddballSession.percent(volume)})'} changes how loud '
              'that is. Calibrate once with a sound level meter to set levels in dB SPL.',
        ),
      ]);
    } else {
      final loudest = session.loudestSpl!;
      final top = math.max(OddballSettings.minSpl, math.min(OddballSettings.maxSpl, loudest.floorToDouble()));
      children.add(
        NumberStepper(
          value: s.levelSpl,
          min: OddballSettings.minSpl,
          max: top,
          step: 1,
          unit: 'dB SPL',
          enabled: !busy,
          onChanged: (v) => set(s.copyWith(levelSpl: v)),
        ),
      );
      if (c.levels.isNotEmpty) {
        children.addAll([
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final level in c.levels)
                ChoiceChip(
                  label: Text('${formatDb(level)} dB'),
                  selected: s.levelSpl == level,
                  onSelected: busy || level > loudest + 0.05 ? null : (_) => set(s.copyWith(levelSpl: level)),
                  labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                ),
            ],
          ),
        ]);
      }
      children.addAll([
        const SizedBox(height: 6),
        Text(
          'Calibrated ${RunChecklist.when(c.date)}'
          '${c.volume == null ? '' : ' at ${OddballSession.percent(c.volume!)} Mac volume'}; '
          'up to ${loudest.floor()} dB SPL.'
          '${c.levels.isEmpty ? '' : ' Quick picks are levels checked with the meter.'}',
          style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
        ),
      ]);
      final problem = session.levelProblem;
      if (problem != null) {
        children.addAll([
          const SizedBox(height: 6),
          _Notice(
            text: problem,
            action: session.volumeChanged
                ? ('Set volume to ${OddballSession.percent(c.volume!)}', session.restoreVolume)
                : null,
          ),
        ]);
      } else if (s.levelSpl > OddballSettings.loudSpl) {
        children.addAll([
          const SizedBox(height: 6),
          _Notice(
            text:
                'Above ${OddballSettings.loudSpl.round()} dB SPL. Check this is the level you mean, and keep '
                'sessions at this level short.',
          ),
        ]);
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// A small caption above a control.
class _Captioned extends StatelessWidget {
  const _Captioned({required this.caption, required this.child});

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(caption, style: const TextStyle(fontSize: 11, color: _muted)),
      const SizedBox(height: 4),
      child,
    ],
  );
}

/// The average response for [channels]: standard and rare traces with ±1 SE
/// bands, their difference, the two tests and how many tones were used. The
/// baseline can be changed from a menu or by dragging across the plot.
class ErpPanel extends StatelessWidget {
  const ErpPanel({super.key, required this.session, required this.channels, this.minus = const []});

  final OddballSession session;
  final List<int> channels;

  /// Subtracted from [channels] for a bipolar derivation; see
  /// [ErpSummary.compute].
  final List<int> minus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, session.progress]),
      builder: (context, _) {
        final summary = session.summary(channels, minus: minus);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _Legend(summary: summary)),
                const SizedBox(width: 10),
                _BaselinePicker(session: session),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ErpPlot(summary: summary, onBaselineChanged: (window) => session.baseline = window),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final tests = [
                  Expanded(
                    child: _TestTile(
                      title: 'Response to every tone',
                      detail: 'Mean ${_ms(ErpSummary.responseWindow)} after onset (auditory N1) vs zero',
                      test: summary.response,
                      needs: 'Needs ${ErpSummary.minTrials} responses',
                      finished: !session.busy,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TestTile(
                      title: 'Rare vs standard',
                      detail: 'Rare minus standard, ${_ms(ErpSummary.oddballWindow)} (P300)',
                      test: summary.oddball,
                      needs: 'Needs ${ErpSummary.minRare} rare and ${ErpSummary.minRare} standard',
                      finished: !session.busy,
                    ),
                  ),
                ];
                final trials = _TrialsTile(session: session, summary: summary);
                // The trials table needs about 210 points; narrower, its row
                // labels would get no width, so it goes under the tests.
                if (constraints.maxWidth >= _TrialsTile.minRowWidth) {
                  return IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [...tests, const SizedBox(width: 12), Expanded(child: trials)],
                    ),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: tests),
                    ),
                    const SizedBox(height: 12),
                    trials,
                  ],
                );
              },
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
        final summaries = [
          for (var c = 0; c < 12; c++) session.summary([c], tests: false),
        ];
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
                            Text(
                              'Ch${c + 1}',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _ink),
                            ),
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
                        Expanded(
                          child: ErpPlot(summary: s, range: range, compact: true),
                        ),
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
                child: Text(
                  side,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: _muted),
                ),
              ),
              for (final c in channels) tile(c),
            ],
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Same scale, ±${_scale(range)} µV. Number: rare minus standard, ${_ms(ErpSummary.oddballWindow)}. '
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
/// difference, onset at 0, the test windows and the baseline shaded. Positive
/// is up.
///
/// With [onBaselineChanged], dragging across the part before onset picks a
/// new baseline window, and hovering reads out the traces.
class ErpPlot extends StatefulWidget {
  const ErpPlot({super.key, required this.summary, this.range, this.compact = false, this.onBaselineChanged});

  final ErpSummary summary;

  /// Half-height in µV; chosen from the data when null.
  final double? range;
  final bool compact;
  final ValueChanged<(double, double)>? onBaselineChanged;

  static const _ranges = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0];

  /// A round half-height that fits [peak] µV, at least 2 µV.
  static double niceRange(double peak) => _ranges.firstWhere((r) => r >= peak && r >= 2, orElse: () => 1000);

  @override
  State<ErpPlot> createState() => _ErpPlotState();
}

class _ErpPlotState extends State<ErpPlot> {
  /// Where the pointer is, seconds after onset.
  double? _hover;

  /// The window being dragged out, and where the drag began.
  (double, double)? _drag;
  double _anchor = 0;

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    if (!widget.compact && summary.isEmpty) {
      return const Center(
        child: Text(
          'The average appears once the first tones have played\n(each response is ready about 2 s after its tone).',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: _muted, height: 1.4),
        ),
      );
    }
    final paint = RepaintBoundary(
      child: CustomPaint(
        painter: _ErpPainter(
          summary,
          range: widget.range ?? ErpPlot.niceRange(summary.peak),
          compact: widget.compact,
          baseline: _drag ?? summary.baseline,
          hover: _hover,
        ),
        size: Size.infinite,
      ),
    );
    final onBaselineChanged = widget.onBaselineChanged;
    if (widget.compact || onBaselineChanged == null) return paint;
    return LayoutBuilder(
      builder: (context, constraints) {
        final plot = _ErpPainter.area(constraints.biggest, compact: false);
        double? timeAt(Offset p) =>
            plot.contains(p) ? ErpEpoch.start + (p.dx - plot.left) / plot.width * (ErpEpoch.end - ErpEpoch.start) : null;
        // The baseline has to come before onset; 10 ms steps.
        double beforeOnset(Offset p) {
          final t = ErpEpoch.start + (p.dx - plot.left) / plot.width * (ErpEpoch.end - ErpEpoch.start);
          return (t.clamp(ErpEpoch.start, 0.0) * 100).round() / 100;
        }

        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          onHover: (e) => setState(() => _hover = timeAt(e.localPosition)),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The window starts where the button went down, not after the slop.
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (d) => setState(() {
              _anchor = beforeOnset(d.localPosition);
              _drag = (_anchor, _anchor);
            }),
            onHorizontalDragUpdate: (d) => setState(() {
              final t = beforeOnset(d.localPosition);
              _drag = (math.min(_anchor, t), math.max(_anchor, t));
              _hover = timeAt(d.localPosition);
            }),
            onHorizontalDragEnd: (_) {
              final window = _drag;
              setState(() => _drag = null);
              if (window != null && window.$2 - window.$1 >= ErpSummary.minBaseline - 1e-9) onBaselineChanged(window);
            },
            onHorizontalDragCancel: () => setState(() => _drag = null),
            child: paint,
          ),
        );
      },
    );
  }
}

class _ErpPainter extends CustomPainter {
  _ErpPainter(this.summary, {required this.range, required this.compact, this.baseline, this.hover});

  final ErpSummary summary;
  final double range;
  final bool compact;

  /// Shaded in the full size, seconds after onset.
  final (double, double)? baseline;

  /// Read out in the full size, seconds after onset.
  final double? hover;

  /// The traces' area within [size].
  static Rect area(Size size, {required bool compact}) =>
      Rect.fromLTRB(compact ? 0.0 : 44.0, compact ? 2.0 : 16.0, size.width, size.height - (compact ? 0.0 : 20.0));

  @override
  void paint(Canvas canvas, Size size) {
    final plot = area(size, compact: compact);
    if (plot.width <= 0 || plot.height <= 0) return;
    double x(double t) => plot.left + plot.width * (t - ErpEpoch.start) / (ErpEpoch.end - ErpEpoch.start);
    double y(double v) => plot.center.dy - v / range * plot.height / 2;
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(
      String s,
      Offset at, {
      Color color = _muted,
      double fontSize = 10,
      bool right = false,
      bool center = false,
    }) {
      label.text = TextSpan(
        text: s,
        style: TextStyle(fontSize: fontSize, color: color, fontFeatures: _tabular),
      );
      label.layout();
      final dx = right ? -label.width : (center ? -label.width / 2 : 0.0);
      label.paint(canvas, at + Offset(dx, -label.height / 2));
    }

    // Baseline and test windows.
    final baseline = this.baseline;
    if (!compact) {
      for (final (window, name, color) in [
        if (baseline != null) (baseline, 'Baseline', const Color(0x12111216)),
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

    final hover = this.hover;
    if (!compact && hover != null) _readout(canvas, plot, x(hover), hover, diff);
  }

  /// A line at [time] and a box with each trace's value there.
  void _readout(Canvas canvas, Rect plot, double at, double time, Float64List? diff) {
    canvas.drawLine(
      Offset(at, plot.top),
      Offset(at, plot.bottom),
      Paint()
        ..color = const Color(0x66111216)
        ..strokeWidth = 1,
    );
    final i = ((time - ErpEpoch.start) * ErpEpoch.rate).round().clamp(0, ErpEpoch.length - 1);
    String uv(double v) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)} µV';
    final s = summary;
    final lines = [
      ('${(ErpEpoch.timeAt(i) * 1000).round()} ms', _ink, FontWeight.w800),
      if (s.standardCount > 0) ('Standard ${uv(s.standardMean[i])}', erpStandardColor, FontWeight.w600),
      if (s.rareCount > 0) ('Rare ${uv(s.rareMean[i])}', erpRareColor, FontWeight.w600),
      if (diff != null) ('Rare − standard ${uv(diff[i])}', erpDifferenceColor, FontWeight.w600),
    ];
    final painters = [
      for (final (text, color, weight) in lines)
        TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontSize: 10.5, color: color, fontWeight: weight, fontFeatures: _tabular),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    const pad = 6.0, gap = 2.0;
    final width = painters.fold(0.0, (w, p) => math.max(w, p.width)) + 2 * pad;
    final height = painters.fold(0.0, (h, p) => h + p.height) + gap * (painters.length - 1) + 2 * pad;
    // Beside the line, on whichever side has room.
    final left = at + 8 + width <= plot.right ? at + 8 : at - 8 - width;
    final box = Rect.fromLTWH(math.max(plot.left, left), plot.top + 4, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(5)),
      Paint()..color = const Color(0xF2FFFFFF),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(5)),
      Paint()
        ..color = _line
        ..style = PaintingStyle.stroke,
    );
    var y = box.top + pad;
    for (final p in painters) {
      p.paint(canvas, Offset(box.left + pad, y));
      y += p.height + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _ErpPainter old) =>
      old.summary != summary ||
      old.range != range ||
      old.compact != compact ||
      old.baseline != baseline ||
      old.hover != hover;
}

/// "300–600 ms" for a window in seconds.
String _ms((double, double) window) => '${(window.$1 * 1000).round()}–${(window.$2 * 1000).round()} ms';

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
          Container(
            width: 14,
            height: 3,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: _ink, fontFeatures: _tabular),
          ),
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
        const Text('Shading ±1 SE · positive up', style: TextStyle(fontSize: 11, color: _muted)),
      ],
    );
  }
}

/// The baseline window: the usual choices, plus one dragged out on the plot.
class _BaselinePicker extends StatelessWidget {
  const _BaselinePicker({required this.session});

  final OddballSession session;

  static String _label((double, double) w) =>
      '${NumberStepper.format(w.$1 * 1000, 0)} to ${NumberStepper.format(w.$2 * 1000, 0)} ms';

  @override
  Widget build(BuildContext context) {
    final current = session.baseline;
    final options = [...ErpSummary.baselineOptions, if (!ErpSummary.baselineOptions.contains(current)) current];
    return Tooltip(
      message:
          'Each average is shifted so its mean over this window is zero. Drag across the plot before '
          '0 ms to choose your own window.',
      waitDuration: const Duration(milliseconds: 400),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Baseline',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _ink),
          ),
          const SizedBox(width: 6),
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _line),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<(double, double)>(
                value: current,
                isDense: true,
                style: const TextStyle(fontSize: 11, color: _ink, fontFeatures: _tabular),
                items: [
                  for (final w in options)
                    DropdownMenuItem(
                      value: w,
                      child: Text(
                        ErpSummary.baselineOptions.contains(w) ? _label(w) : '${_label(w)} (dragged)',
                      ),
                    ),
                ],
                onChanged: (w) {
                  if (w != null) session.baseline = w;
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tones played, used in the average and left out, for standard and rare.
class _TrialsTile extends StatelessWidget {
  const _TrialsTile({required this.session, required this.summary});

  /// Narrowest row that fits the two test tiles and this one side by side.
  static const minRowWidth = 660.0;

  final OddballSession session;
  final ErpSummary summary;

  @override
  Widget build(BuildContext context) {
    final (:standard, :rare) = session.trialCounts(summary);
    final played = standard.played + rare.played;
    final settled = played - standard.waiting - rare.waiting;
    final used = standard.used + rare.used;
    final rejected = standard.rejected + rare.rejected;

    // Why: lost EEG, over the threshold, and tones cut off by stopping a run.
    final lost = session.rejections;
    final lostTotal = lost.values.fold(0, (a, b) => a + b);
    final cutOff = math.max(0, rejected - lostTotal - summary.artifactCount);
    final reasons = [
      if (summary.artifactCount > 0) '${summary.artifactCount} over ${session.rejectAbove?.round()} µV',
      for (final e in lost.entries)
        if (e.value > 0) '${e.value} ${e.key.label}',
      if (cutOff > 0) '$cutOff cut off by stopping',
      if (settled < played) '${played - settled} waiting for EEG',
    ];

    const head = TextStyle(fontSize: 10, color: _muted, fontWeight: FontWeight.w700);
    const cell = TextStyle(fontSize: 11.5, color: _ink, fontWeight: FontWeight.w700, fontFeatures: _tabular);
    Widget number(int n, {TextStyle style = cell}) => Text('$n', textAlign: TextAlign.right, style: style);
    TableRow row(String name, Color color, TrialCounts c) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 5),
              Text(name, style: const TextStyle(fontSize: 11, color: _ink)),
            ],
          ),
        ),
        number(c.used),
        number(c.rejected, style: cell.copyWith(color: c.rejected > 0 ? erpRareColor : _ink)),
        number(c.played, style: cell.copyWith(color: _muted, fontWeight: FontWeight.w400)),
      ],
    );

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
                  'Trials used',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink),
                ),
              ),
              if (settled > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: const Color(0xFFF1F2F5), borderRadius: BorderRadius.circular(10)),
                  child: Text(
                    '${(used / settled * 100).round()}%',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _ink),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(),
              1: IntrinsicColumnWidth(),
              2: IntrinsicColumnWidth(),
              3: IntrinsicColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(
                children: [
                  const SizedBox(),
                  for (final h in const ['Used', 'Rejected', 'Played'])
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(h, textAlign: TextAlign.right, style: head),
                    ),
                ],
              ),
              row('Standard', erpStandardColor, standard),
              row('Rare', erpRareColor, rare),
            ],
          ),
          if (reasons.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(reasons.join(' · '), style: const TextStyle(fontSize: 10.5, color: _muted, height: 1.3)),
          ],
        ],
      ),
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
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink),
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
              DropdownMenuItem(
                value: d.id,
                child: Text(d.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: enabled ? (id) => session.output = outputs.where((d) => d.id == id).firstOrNull : null,
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
      Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
      ),
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
                DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value, overflow: TextOverflow.ellipsis),
                ),
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
  const _Notice({required this.text, this.action});

  final String text;

  /// A button under the text: its label and what it does.
  final (String, VoidCallback)? action;

  static const _brown = Color(0xFF7A4B00);

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xFFF3D9A4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(fontSize: 11, color: _brown, height: 1.35)),
          if (action != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 28,
              child: OutlinedButton(
                onPressed: action.$2,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _brown,
                  side: const BorderSide(color: Color(0xFFE2B865)),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                ),
                child: Text(action.$1, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
