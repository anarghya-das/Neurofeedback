import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// Bench-test app for the MW75 driver.
///
/// `--dart-define=MW75_AUTOSTART=1` starts the first paired MW75 on launch and
/// `--dart-define=MW75_AUTOSTOP=<seconds>` stops it again, printing status lines
/// to the console; that is how the driver is exercised against real hardware
/// without clicking.
void main() => runApp(const BenchApp());

const _autostart = bool.fromEnvironment('MW75_AUTOSTART');
const _autostopSeconds = int.fromEnvironment('MW75_AUTOSTOP');

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'MW75 bench test',
    theme: ThemeData(scaffoldBackgroundColor: const Color(0xFFF7F7F8), colorSchemeSeed: _ink),
    home: const BenchPage(),
  );
}

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> with SingleTickerProviderStateMixin {
  final headset = Mw75Headset();
  final metrics = Mw75MetricSession();
  late final oddball = OddballSession(headset: headset, store: _store);
  late final alpha = AlphaSession(headset: headset, store: _store);

  /// Finished test runs: one folder each, with results and the raw EEG.
  static final _store = TestRunStore(Directory('${Platform.environment['HOME']}/Documents/MW75 Tests'));
  final plot = _PlotBuffer(seconds: _EegPainter.window);
  StreamSubscription<List<Mw75Sample>>? _samples;
  Timer? _consoleStatus;
  final _streamName = TextEditingController(text: Mw75Headset.defaultStreamName);

  final bands = BandPowerEstimator();
  final _bandPowers = ValueNotifier<BandPowers?>(null);

  /// Drives the live plot: one repaint per screen refresh while streaming.
  late final AnimationController _frames = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  _ChannelSet _bandSource = const _ChannelSet.all();
  _ChannelSet _erpSource = const _ChannelSet.all();
  _ChannelSet _alphaSource = const _ChannelSet.all();
  _View _view = _View.live;
  Timer? _bandTimer;
  HeadsetState? _lastState;

  @override
  void initState() {
    super.initState();
    _samples = headset.samples.listen((s) {
      plot.addAll(s);
      bands.addAll(s);
    });
    headset.addListener(_onHeadsetChanged);
    _bandTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _updateBands());
    // Always echo a once-a-second status line to the console so the driver can
    // be watched live from a terminal, not just the on-screen log.
    _consoleStatus = Timer.periodic(const Duration(seconds: 1), (_) {
      if (metrics.state != MetricState.idle) {
        debugPrint(
          '[bench] focus ${metrics.state.name}${metrics.paused ? ' PAUSED' : ''} focus=${metrics.focus?.toStringAsFixed(3)} '
          'left=${metrics.leftContact} right=${metrics.rightContact} contactMsgs=${metrics.contactMessages} '
          'records=${metrics.records}',
        );
      }
      if (oddball.busy) {
        final s = oddball.summary(_erpSource.channels);
        String p(WindowTest? t) => t == null ? '-' : '${t.effect.toStringAsFixed(2)}uV p=${t.p.toStringAsFixed(3)}';
        debugPrint(
          '[bench] oddball ${oddball.state.name} tone ${oddball.trialsPlayed}/${oddball.plannedTrials} '
          'epochs std=${s.standardCount} rare=${s.rareCount} artifacts=${s.artifactCount} '
          'unusable=${oddball.rejections.map((k, v) => MapEntry(k.name, v))} '
          'N1 ${p(s.response)} P300 ${p(s.oddball)} latency=${oddball.outputInfo?.latency.toStringAsFixed(3)}',
        );
      }
      if (alpha.busy) {
        final s = alpha.summary(_alphaSource.channels);
        debugPrint(
          '[bench] alpha ${alpha.state.name} block ${alpha.blockNumber}/${alpha.blockCount} '
          'eyes=${alpha.eyesClosedNow == true ? 'closed' : 'open'} windows=${alpha.current?.timeline.length} '
          'blocks open=${s.openBlocks} closed=${s.closedBlocks} ratio=${s.ratio?.toStringAsFixed(2)} '
          'p=${s.p?.toStringAsFixed(4)} peak=${s.peakHz?.toStringAsFixed(1)}Hz',
        );
      }
      if (headset.state == HeadsetState.idle) return;
      debugPrint(
        '[bench] ${headset.state.name} rate=${headset.packetRate.toStringAsFixed(0)}/s '
        'effRate=${headset.effectiveRate?.toStringAsFixed(1)} '
        'received=${headset.packetsReceived} lost=${headset.packetsLost} '
        '(${(headset.lossRatio * 100).toStringAsFixed(1)}%) '
        'recentLoss=${headset.recentLossRatio == null ? '-' : '${(headset.recentLossRatio! * 100).toStringAsFixed(1)}%'} '
        'longDropouts=${headset.longDropouts} checksum=${headset.checksumErrors} '
        'battery=${headset.batteryPercent} lslConsumers=${headset.lslHasConsumers} '
        'headsetCups=${headset.leftCupContact}/${headset.rightCupContact} '
        'quality=${jsonEncode(headset.quality?.toJson())}',
      );
    });
    unawaited(_boot());
  }

  Future<void> _boot() async {
    if (_autostart) debugPrint('[bench] listing paired devices…');
    await headset.refreshDevices();
    await oddball.refreshOutputs();
    await oddball.loadSaved();
    await alpha.loadSaved();
    if (!_autostart) return;
    debugPrint('[bench] devices: ${headset.devices}');
    await headset.start();
    debugPrint('[bench] after start: ${headset.state.name}: ${headset.statusText}');
    if (_autostopSeconds > 0) {
      await Future<void>.delayed(const Duration(seconds: _autostopSeconds));
      await headset.stop();
      debugPrint('[bench] after stop: ${headset.state.name}: ${headset.statusText}');
    }
  }

  /// A new stream starts with an empty band-power history.
  void _onHeadsetChanged() {
    final state = headset.state;
    if (state == HeadsetState.starting && _lastState != HeadsetState.starting) {
      bands.clear();
      plot.clear();
      _bandPowers.value = null;
    }
    // Repaint the plot every frame only while there is something to scroll.
    if (state == HeadsetState.streaming) {
      if (!_frames.isAnimating) _frames.repeat();
    } else if (_frames.isAnimating) {
      _frames.stop();
    }
    _lastState = state;
  }

  void _updateBands() {
    if (headset.state != HeadsetState.streaming || !mounted) return;
    final p = bands.compute(
      sampleRate: headset.effectiveRate ?? Mw75Protocol.samplingRate,
      channels: _bandSource.channels,
    );
    if (p == null) return;
    _bandPowers.value = p;
  }

  @override
  void dispose() {
    _bandTimer?.cancel();
    headset.removeListener(_onHeadsetChanged);
    _samples?.cancel();
    _frames.dispose();
    _bandPowers.dispose();
    _consoleStatus?.cancel();
    oddball.dispose();
    alpha.dispose();
    headset.dispose();
    metrics.dispose();
    _streamName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 360,
              child: ListView(
                children: [
                  // Tested on the lab headset: while raw EEG is on, it holds a Focus
                  // start request and only starts Focus once raw mode is switched
                  // off. So the two run one at a time, as in Research Kit.
                  ListenableBuilder(
                    listenable: Listenable.merge([headset, metrics]),
                    builder: (context, _) {
                      final rawActive =
                          headset.state == HeadsetState.starting || headset.state == HeadsetState.streaming;
                      final focusActive =
                          metrics.state == MetricState.connecting || metrics.state == MetricState.running;
                      return Column(
                        children: [
                          _Card(
                            title: 'Headset',
                            trailing: HeadsetStatusBadge(headset: headset),
                            child: HeadsetPanel(
                              headset: headset,
                              startBlockedReason: focusActive
                                  ? 'Stop Focus first: the headset runs Focus and raw EEG one at a time.'
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _Card(
                            title: 'Focus',
                            child: FocusPanel(
                              session: metrics,
                              startBlockedReason: rawActive
                                  ? 'Stop raw EEG first: the headset only starts Focus once raw mode is off.'
                                  : null,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  _Card(
                    title: 'Stream',
                    child: _StreamSettings(headset: headset, name: _streamName),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<_View>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    segments: const [
                      ButtonSegment(value: _View.live, label: Text('Live signals')),
                      ButtonSegment(value: _View.oddball, label: Text('Auditory oddball')),
                      ButtonSegment(value: _View.alpha, label: Text('Eyes-closed alpha')),
                    ],
                    selected: {_view},
                    onSelectionChanged: (v) => setState(() => _view = v.first),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: switch (_view) {
                      _View.live => _liveView(),
                      _View.oddball => _oddballView(),
                      _View.alpha => _alphaView(),
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _liveView() => Column(
    children: [
      Expanded(
        flex: 3,
        child: _Card(
          title: 'Live EEG',
          trailing: const Text(
            'Last 4 s, drawn 0.35 s behind live, offset removed',
            style: TextStyle(fontSize: 11, color: _muted),
          ),
          child: Expanded(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _EegPainter(plot, repaint: _frames),
                size: Size.infinite,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      Expanded(
        flex: 2,
        child: _Card(
          title: 'Band power',
          trailing: _ChannelSetPicker(
            value: _bandSource,
            onChanged: (v) => setState(() {
              _bandSource = v;
              _bandPowers.value = null;
            }),
          ),
          child: Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([headset, _bandPowers]),
              builder: (context, _) =>
                  _BandPowerView(powers: headset.state == HeadsetState.streaming ? _bandPowers.value : null),
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      Expanded(
        flex: 2,
        child: _Card(
          title: 'Command log',
          child: Expanded(
            child: _Log(headset: headset, metrics: metrics),
          ),
        ),
      ),
    ],
  );

  Widget _oddballView() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 340,
        child: ListView(
          children: [
            _Card(
              title: 'Auditory oddball',
              child: ListenableBuilder(
                listenable: Listenable.merge([headset, alpha]),
                builder: (context, _) => OddballControls(
                  session: oddball,
                  startBlockedReason: headset.state != HeadsetState.streaming
                      ? 'Start raw EEG in the Headset card first.'
                      : alpha.busy
                      ? 'Wait for the alpha test to finish.'
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          children: [
            Expanded(
              flex: 3,
              child: _Card(
                title: 'Average response',
                trailing: _ChannelSetPicker(value: _erpSource, onChanged: (v) => setState(() => _erpSource = v)),
                child: Expanded(
                  child: ErpPanel(session: oddball, channels: _erpSource.channels),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              flex: 2,
              child: _Card(
                title: 'Each channel',
                trailing: const Text('Tap one to show it above', style: TextStyle(fontSize: 11, color: _muted)),
                child: Expanded(
                  child: ErpChannelGrid(
                    session: oddball,
                    selected: _erpSource.channel,
                    onSelected: (c) => setState(() => _erpSource = _ChannelSet.channel(c)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _alphaView() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 340,
        child: ListView(
          children: [
            _Card(
              title: 'Eyes-closed alpha',
              child: ListenableBuilder(
                listenable: Listenable.merge([headset, oddball]),
                builder: (context, _) => AlphaControls(
                  session: alpha,
                  startBlockedReason: headset.state != HeadsetState.streaming
                      ? 'Start raw EEG in the Headset card first.'
                      : oddball.busy
                      ? 'Wait for the oddball test to finish.'
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          children: [
            Expanded(
              flex: 2,
              child: _Card(
                title: 'Alpha over time',
                trailing: _ChannelSetPicker(value: _alphaSource, onChanged: (v) => setState(() => _alphaSource = v)),
                child: Expanded(
                  child: AlphaTimeline(session: alpha, channels: _alphaSource.channels),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              flex: 3,
              child: _Card(
                title: 'Spectrum',
                trailing: Text(_alphaSource.label, style: const TextStyle(fontSize: 11, color: _muted)),
                child: Expanded(
                  child: AlphaSpectrumPanel(session: alpha, channels: _alphaSource.channels),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              flex: 2,
              child: _Card(
                title: 'Each channel',
                trailing: const Text('Tap one to show it above', style: TextStyle(fontSize: 11, color: _muted)),
                child: Expanded(
                  child: AlphaChannelBars(
                    session: alpha,
                    selected: _alphaSource.channel,
                    onSelected: (c) => setState(() => _alphaSource = _ChannelSet.channel(c)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

enum _View { live, oddball, alpha }

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  // A Material rather than a decorated box, so list tiles and buttons inside
  // can paint their ink on it.
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: _line),
    ),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}

class _StreamSettings extends StatelessWidget {
  const _StreamSettings({required this.headset, required this.name});

  final Mw75Headset headset;
  final TextEditingController name;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: headset,
    builder: (context, _) {
      final idle = headset.state == HeadsetState.idle || headset.state == HeadsetState.error;
      Widget stat(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12, color: _muted)),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
            ),
          ],
        ),
      );
      Widget toggle(String label, bool value, ValueChanged<bool>? onChanged) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 12)),
        value: value,
        onChanged: onChanged,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          stat('Packets per second', headset.packetRate.toStringAsFixed(0)),
          stat(
            'Measured sample rate',
            headset.state != HeadsetState.streaming
                ? '–'
                : headset.effectiveRate == null
                ? 'measuring…'
                : '${headset.effectiveRate!.toStringAsFixed(1)} Hz',
          ),
          stat('Received', '${headset.packetsReceived}'),
          stat('Lost in transit', '${headset.packetsLost} (${(headset.lossRatio * 100).toStringAsFixed(1)}%)'),
          stat('Long dropouts (> 0.5 s)', '${headset.longDropouts}'),
          stat('Checksum errors', '${headset.checksumErrors}'),
          stat('Firmware', headset.firmwareVersion ?? '–'),
          stat('LSL consumers', headset.lslHasConsumers ? 'connected' : 'none'),
          const SizedBox(height: 10),
          TextField(
            controller: name,
            enabled: idle,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              labelText: 'LSL stream name',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => headset.streamName = v.trim().isEmpty ? Mw75Headset.defaultStreamName : v.trim(),
          ),
          const SizedBox(height: 6),
          toggle('Publish to LSL', headset.publishToLsl, idle ? (v) => headset.publishToLsl = v : null),
          toggle('Fill lost packets (interpolate)', headset.interpolate, (v) => headset.interpolate = v),
          toggle('Remove DC offset (0.5 Hz high-pass)', headset.removeDcOffset, (v) => headset.removeDcOffset = v),
        ],
      );
    },
  );
}

class _Log extends StatelessWidget {
  const _Log({required this.headset, required this.metrics});

  final Mw75Headset headset;
  final Mw75MetricSession metrics;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([headset, metrics]),
    builder: (context, _) {
      // Both sessions' traffic, newest first; Focus lines are marked.
      final entries = [for (final e in headset.log) (e, false), for (final e in metrics.log) (e, true)]
        ..sort((a, b) => b.$1.time.compareTo(a.$1.time));
      return ListView.builder(
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final (e, focus) = entries[i];
          final t = e.time.toIso8601String().substring(11, 23);
          return Text(
            '$t  ${focus ? '[focus] ' : ''}${e.message}',
            style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: 11,
              color: focus ? const Color(0xFF4F39F6) : _ink,
              height: 1.4,
            ),
          );
        },
      );
    },
  );
}

/// Recent Ch1–Ch12 samples and their LSL timestamps, for the live plot.
class _PlotBuffer {
  _PlotBuffer({required double seconds})
    : capacity = ((seconds + _EegPainter.delay + 1) * Mw75Protocol.samplingRate).toInt();

  final int capacity;
  final times = <double>[];
  final channels = List.generate(Mw75Protocol.eegChannelCount, (_) => <double>[]);

  void addAll(List<Mw75Sample> samples) {
    for (final s in samples) {
      times.add(s.time);
      for (var c = 0; c < channels.length; c++) {
        channels[c].add(s.values[c]);
      }
    }
    // Trim in chunks so most batches do not shift the whole list.
    final excess = times.length - capacity;
    if (excess > 250) {
      times.removeRange(0, excess);
      for (final ch in channels) {
        ch.removeRange(0, excess);
      }
    }
  }

  void clear() {
    times.clear();
    for (final ch in channels) {
      ch.clear();
    }
  }

  /// Index of the first sample at or after [t] (times are increasing).
  int firstAtOrAfter(double t) {
    var lo = 0, hi = times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// Scrolls by time, not by sample count: each frame shows the [window] ending
/// [delay] before now. Bluetooth delivers samples in bursts; drawing slightly
/// in the past means a burst is already in hand when its time comes, so the
/// traces glide at real speed instead of jumping whenever data lands.
class _EegPainter extends CustomPainter {
  _EegPainter(this.buffer, {required Listenable repaint}) : super(repaint: repaint);

  static const window = 4.0;
  static const delay = 0.35;
  final _PlotBuffer buffer;

  @override
  void paint(Canvas canvas, Size size) {
    final lanes = buffer.channels.length;
    final laneHeight = size.height / lanes;
    final label = TextPainter(textDirection: TextDirection.ltr);
    final grid = Paint()..color = const Color(0xFFEEF0F3);
    final trace = Paint()
      ..color = const Color(0xFF2B4C7E)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const labelWidth = 34.0;
    final plotWidth = size.width - labelWidth;
    const halfRangeUv = 100.0;

    final end = LslEegOutlet.localClock() - delay;
    final start = end - window;
    final first = buffer.firstAtOrAfter(start);
    final last = buffer.firstAtOrAfter(end); // exclusive
    final count = last - first;
    final step = math.max(1, count ~/ math.max(1, plotWidth.toInt()));

    for (var c = 0; c < lanes; c++) {
      final mid = laneHeight * (c + 0.5);
      canvas.drawLine(Offset(labelWidth, mid), Offset(size.width, mid), grid);
      label.text = TextSpan(
        text: 'Ch${c + 1}',
        style: const TextStyle(fontSize: 10, color: _muted),
      );
      label.layout();
      label.paint(canvas, Offset(0, mid - label.height / 2));
      if (count < 2) continue;

      final data = buffer.channels[c];
      var mean = 0.0;
      for (var i = first; i < last; i++) {
        mean += data[i];
      }
      mean /= count;
      final path = Path();
      for (var i = first; i < last; i += step) {
        final x = labelWidth + plotWidth * (buffer.times[i] - start) / window;
        final v = ((data[i] - mean) / halfRangeUv).clamp(-1.0, 1.0);
        final y = mid - v * laneHeight * 0.45;
        if (i == first) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, trace);
    }
  }

  @override
  bool shouldRepaint(covariant _EegPainter oldDelegate) => oldDelegate.buffer != buffer;
}

/// Which EEG channels band power or the ERP is averaged over.
class _ChannelSet {
  const _ChannelSet.all() : side = null, channel = null;
  const _ChannelSet.side(EarSide this.side) : channel = null;
  const _ChannelSet.channel(int this.channel) : side = null;

  final EarSide? side;
  final int? channel;

  List<int> get channels => switch ((side, channel)) {
    (_, final int c) => [c],
    (EarSide.left, _) => [0, 1, 2, 3, 4, 5],
    (EarSide.right, _) => [6, 7, 8, 9, 10, 11],
    _ => List.generate(Mw75Protocol.eegChannelCount, (i) => i),
  };

  String get label => switch ((side, channel)) {
    (_, final int c) => 'Ch${c + 1}',
    (EarSide.left, _) => 'Left cup (Ch1–6)',
    (EarSide.right, _) => 'Right cup (Ch7–12)',
    _ => 'All EEG channels',
  };

  static final options = [
    const _ChannelSet.all(),
    const _ChannelSet.side(EarSide.left),
    const _ChannelSet.side(EarSide.right),
    for (var c = 0; c < Mw75Protocol.eegChannelCount; c++) _ChannelSet.channel(c),
  ];

  @override
  bool operator ==(Object other) => other is _ChannelSet && other.side == side && other.channel == channel;

  @override
  int get hashCode => Object.hash(side, channel);
}

class _ChannelSetPicker extends StatelessWidget {
  const _ChannelSetPicker({required this.value, required this.onChanged});

  final _ChannelSet value;
  final ValueChanged<_ChannelSet> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_ChannelSet>(
    tooltip: 'Channels to average',
    initialValue: value,
    onSelected: onChanged,
    position: PopupMenuPosition.under,
    itemBuilder: (context) => [
      for (final o in _ChannelSet.options)
        PopupMenuItem(
          value: o,
          height: 32,
          child: Text(o.label, style: const TextStyle(fontSize: 12)),
        ),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: _line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value.label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _ink),
          ),
          const SizedBox(width: 6),
          const Icon(Icons.expand_more_rounded, size: 16, color: _muted),
        ],
      ),
    ),
  );
}

const _tabular = [FontFeature.tabularFigures()];

/// One vertical bar per band: relative power as the bar, the percentage and
/// absolute µV²/Hz above it, the band name and range below.
class _BandPowerView extends StatelessWidget {
  const _BandPowerView({required this.powers});

  final BandPowers? powers;

  static String _hz(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  static String _density(double v) {
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
    if (v >= 100) return v.toStringAsFixed(0);
    if (v >= 10) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    final p = powers;
    if (p == null) {
      return const Center(
        child: Text(
          'Band power appears about 2 s after streaming starts.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: _muted),
        ),
      );
    }
    final animate = !MediaQuery.of(context).disableAnimations;
    return LayoutBuilder(
      builder: (context, box) {
        // On a short card, keep the bars and drop the secondary lines rather
        // than overflow.
        final compact = box.maxHeight < 130;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final band in EegBand.values)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${(p.relative[band]! * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                        fontFeatures: _tabular,
                      ),
                    ),
                    if (!compact)
                      Text(
                        '${_density(p.density[band]!)} µV²/Hz',
                        style: const TextStyle(fontSize: 9.5, color: _muted, fontFeatures: _tabular),
                      ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, bar) {
                          final width = math.min(44.0, bar.maxWidth * 0.6);
                          return Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              Container(
                                width: width,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF1F2F5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              AnimatedContainer(
                                duration: animate ? const Duration(milliseconds: 180) : Duration.zero,
                                width: width,
                                height: bar.maxHeight * p.relative[band]!.clamp(0.0, 1.0),
                                decoration: BoxDecoration(
                                  color: Color(band.color),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      band.label,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _ink),
                    ),
                    if (!compact)
                      Text(
                        '${_hz(band.low)}–${_hz(band.high)} Hz',
                        style: const TextStyle(fontSize: 10, color: _muted),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
