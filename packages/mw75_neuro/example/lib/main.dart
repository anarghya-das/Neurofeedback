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
  late final focus = FocusSession(headset: headset, store: _store);

  /// Finished test runs: one folder each, with results and the raw EEG.
  static final _store = TestRunStore(Directory('${Platform.environment['HOME']}/Documents/MW75 Tests'));
  final plot = EegPlotBuffer(seconds: EegTracePainter.maxWindow);

  /// Live EEG view: per-channel scale (± µV; 0 = automatic) and time window.
  int _eegScale = 100;
  double _eegWindow = 4;

  /// Per-channel limits for the automatic scale, OpenBCI GUI style.
  final _eegAuto = EegAutoScale();
  Offset? _eegHover;
  StreamSubscription<List<Mw75Sample>>? _samples;
  Timer? _consoleStatus;
  final _streamName = TextEditingController(text: Mw75Headset.defaultStreamName);

  final bands = BandPowerEstimator();
  final _bandPowers = ValueNotifier<BandPowers?>(null);

  /// Per channel shown: (channel index, its spectrum).
  final _spectrum = ValueNotifier<List<(int, PowerSpectrum)>?>(null);
  _BandView _bandView = _BandView.bars;

  /// The command log starts folded; its header opens it.
  bool _logOpen = false;

  /// Drives the live plot: one repaint per screen refresh while streaming.
  late final AnimationController _frames = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  _ChannelSet _bandSource = const _ChannelSet.all();

  /// Both cups' top-minus-bottom pairs: where around-the-ear studies find the
  /// P300 strongest, chosen before looking at results.
  _ChannelSet _erpSource = const _ChannelSet.bipolar();
  _ChannelSet _alphaSource = const _ChannelSet.all();
  _View _view = _View.live;

  /// The side panel (headset, Neurable Focus, filters, stream); hidden, the
  /// views get the whole window.
  bool _panelOpen = true;
  FocusVisual _focusVisual = FocusVisual.flame;
  static const _panelWidth = 360.0;
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
        final s = oddball.summary(_erpSource.channels, minus: _erpSource.minus);
        String p(WindowTest? t) => t == null ? '-' : '${t.effect.toStringAsFixed(2)}uV p=${t.p.toStringAsFixed(3)}';
        debugPrint(
          '[bench] oddball ${oddball.state.name} tone ${oddball.trialsPlayed}/${oddball.plannedTrials} '
          'epochs std=${s.standardCount} rare=${s.rareCount} artifacts=${s.artifactCount} '
          'unusable=${oddball.rejections.map((k, v) => MapEntry(k.name, v))} '
          'N1 ${p(s.response)} P300 ${p(s.oddball)} latency=${oddball.outputInfo?.latency.toStringAsFixed(3)}',
        );
      }
      if (focus.model != null && headset.state == HeadsetState.streaming) {
        debugPrint(
          '[bench] focus ${focus.state.name} score=${focus.score?.toStringAsFixed(1)} noisy=${focus.noisy} '
          'block=${focus.blockNumber}/${focus.blockCount} auc=${focus.model?.cvAuc.toStringAsFixed(2)}'
          '${focus.noisyReason == null ? '' : ' why=${focus.noisyReason}'}',
        );
      }
      if (alpha.busy) {
        final s = alpha.summary(_alphaSource.channels);
        debugPrint(
          '[bench] alpha ${alpha.state.name} block ${alpha.blockNumber}/${alpha.blockCount} '
          'eyes=${alpha.eyesClosedNow == true ? 'closed' : 'open'} windows=${alpha.current?.timeline.length} '
          'blocks open=${s.openBlocks} closed=${s.closedBlocks} ratio=${s.ratio?.toStringAsFixed(2)} '
          'p=${s.p?.toStringAsFixed(4)} peak=${s.peakHz?.toStringAsFixed(1)}Hz '
          'share=${s.shareRatio?.toStringAsFixed(2)} shareP=${s.shareP?.toStringAsFixed(4)}',
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
    await focus.loadSaved();
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
      _eegAuto.clear();
      _bandPowers.value = null;
      _spectrum.value = null;
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
    final rate = headset.effectiveRate ?? Mw75Protocol.samplingRate;
    switch (_bandView) {
      case _BandView.bars:
        final p = bands.compute(sampleRate: rate, channels: _bandSource.channels);
        if (p != null) _bandPowers.value = p;
      case _BandView.spectrum:
        final channels = _bandSource.channels;
        final p = bands.spectra(sampleRate: rate, channels: channels);
        if (p != null) _spectrum.value = [for (var i = 0; i < p.length; i++) (channels[i], p[i])];
    }
  }

  @override
  void dispose() {
    _bandTimer?.cancel();
    headset.removeListener(_onHeadsetChanged);
    _samples?.cancel();
    _frames.dispose();
    _bandPowers.dispose();
    _spectrum.dispose();
    _consoleStatus?.cancel();
    oddball.dispose();
    alpha.dispose();
    focus.dispose();
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
            // Slides shut by shrinking to zero width; the panel keeps its size
            // inside, clipped, so nothing reflows and its state is kept.
            AnimatedContainer(
              duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: _panelOpen ? _panelWidth + 18 : 0,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: _panelWidth + 18,
                  maxWidth: _panelWidth + 18,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 18),
                    child: ExcludeFocus(
                      excluding: !_panelOpen,
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
                                    title: 'Neurable Focus',
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
                            title: 'Filters',
                            child: FilterSettingsPanel(headset: headset),
                          ),
                          const SizedBox(height: 14),
                          _Card(
                            title: 'Stream',
                            child: _StreamSettings(headset: headset, name: _streamName),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Tooltip(
                        message: _panelOpen ? 'Hide the side panel' : 'Show the side panel',
                        child: IconButton.outlined(
                          onPressed: () => setState(() => _panelOpen = !_panelOpen),
                          icon: Icon(_panelOpen ? Icons.chevron_left_rounded : Icons.view_sidebar_outlined, size: 18),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            minimumSize: const Size(36, 36),
                            side: const BorderSide(color: _line),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
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
                          ButtonSegment(value: _View.focus, label: Text('Your focus')),
                        ],
                        selected: {_view},
                        onSelectionChanged: (v) => setState(() => _view = v.first),
                      ),
                      const Spacer(),
                      // With the panel hidden, still show whether EEG is streaming.
                      if (!_panelOpen) HeadsetStatusBadge(headset: headset),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: switch (_view) {
                      _View.live => _liveView(),
                      _View.oddball => _oddballView(),
                      _View.alpha => _alphaView(),
                      _View.focus => _focusView(),
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Picker<int>(
                value: _eegScale,
                options: const [0, ...EegTracePainter.scaleOptions],
                label: (v) => v == 0 ? 'Scale: auto (per channel)' : 'Scale: ±$v µV',
                tooltip: 'Vertical scale, per channel',
                onChanged: (v) => setState(() {
                  _eegScale = v;
                  _eegAuto.clear();
                }),
              ),
              const SizedBox(width: 8),
              _Picker<double>(
                value: _eegWindow,
                options: EegTracePainter.windowOptions,
                label: (v) => 'Window: ${v.round()} s',
                tooltip: 'Seconds shown across the plot: longer scrolls slower',
                onChanged: (v) => setState(() => _eegWindow = v),
              ),
            ],
          ),
          child: Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListenableBuilder(
                  listenable: headset,
                  builder: (context, _) => Text(
                    'Filters: ${headset.filters.describe()} · '
                    '${_eegScale == 0 ? 'each channel scaled to its own min–max, updated every second' : 'each channel centred on its mean'} · '
                    'drawn ${EegTracePainter.delay} s behind live · hover to read values',
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: MouseRegion(
                    onHover: (e) => setState(() => _eegHover = e.localPosition),
                    onExit: (_) => setState(() => _eegHover = null),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: EegTracePainter(
                          plot,
                          repaint: _frames,
                          window: _eegWindow,
                          halfRangeUv: _eegScale.toDouble(),
                          autoScale: _eegScale == 0 ? _eegAuto : null,
                          hover: _eegHover,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      Expanded(
        flex: 2,
        child: _Card(
          title: 'Band power',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Picker<_BandView>(
                value: _bandView,
                options: _BandView.values,
                label: (v) => v.label,
                tooltip: 'What to show',
                onChanged: (v) => setState(() {
                  _bandView = v;
                  _updateBands();
                }),
              ),
              const SizedBox(width: 8),
              _ChannelSetPicker(
                value: _bandSource,
                onChanged: (v) => setState(() {
                  _bandSource = v;
                  _bandPowers.value = null;
                  _spectrum.value = null;
                }),
              ),
            ],
          ),
          child: Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([headset, _bandPowers, _spectrum]),
              builder: (context, _) {
                final streaming = headset.state == HeadsetState.streaming;
                return switch (_bandView) {
                  _BandView.bars => _BandPowerView(powers: streaming ? _bandPowers.value : null),
                  _BandView.spectrum => ChannelSpectrumPlot(
                    spectrum: streaming ? _spectrum.value : null,
                    filters: headset.filters,
                    mainsHz: headset.mainsHz,
                  ),
                };
              },
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      if (_logOpen)
        Expanded(
          flex: 2,
          child: _Card(
            title: 'Command log',
            onHeaderTap: () => setState(() => _logOpen = false),
            trailing: const _FoldLabel(open: true),
            child: Expanded(
              child: _Log(headset: headset, metrics: metrics),
            ),
          ),
        )
      else
        _Card(
          title: 'Command log',
          onHeaderTap: () => setState(() => _logOpen = true),
          trailing: const _FoldLabel(open: false),
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
                listenable: Listenable.merge([headset, alpha, focus]),
                builder: (context, _) => OddballControls(
                  session: oddball,
                  startBlockedReason: _testBlockedReason(except: oddball),
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
                trailing: _ChannelSetPicker(
                  value: _erpSource,
                  erp: true,
                  onChanged: (v) => setState(() => _erpSource = v),
                ),
                child: Expanded(
                  child: ErpPanel(session: oddball, channels: _erpSource.channels, minus: _erpSource.minus),
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
                listenable: Listenable.merge([headset, oddball, focus]),
                builder: (context, _) => AlphaControls(
                  session: alpha,
                  startBlockedReason: _testBlockedReason(except: alpha),
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

  /// Why a guided test cannot start now: no EEG, or another test running.
  String? _testBlockedReason({required Object except}) {
    if (headset.state != HeadsetState.streaming) return 'Start raw EEG in the Headset card first.';
    if (!identical(except, oddball) && oddball.busy) return 'Wait for the oddball test to finish.';
    if (!identical(except, alpha) && alpha.busy) return 'Wait for the alpha test to finish.';
    if (!identical(except, focus) && focus.calibrating) return 'Wait for the focus calibration to finish.';
    return null;
  }

  Widget _focusView() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 340,
        child: ListView(
          children: [
            _Card(
              title: 'Your focus',
              child: ListenableBuilder(
                listenable: Listenable.merge([headset, oddball, alpha]),
                builder: (context, _) => FocusControls(
                  session: focus,
                  startBlockedReason: _testBlockedReason(except: focus),
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
                title: 'Focus now',
                trailing: _Picker<FocusVisual>(
                  value: _focusVisual,
                  options: FocusVisual.values,
                  label: (v) => v.label,
                  tooltip: 'How the score is pictured',
                  onChanged: (v) => setState(() => _focusVisual = v),
                ),
                child: Expanded(
                  child: FocusScoreView(session: focus, visual: _focusVisual),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              flex: 2,
              child: _Card(
                title: 'Over the last 5 minutes',
                trailing: const Text(
                  'Dashed: target · shaded: too noisy to score',
                  style: TextStyle(fontSize: 11, color: _muted),
                ),
                child: Expanded(child: FocusTimeline(session: focus)),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

enum _View { live, oddball, alpha, focus }

enum _BandView {
  bars('Band power'),
  spectrum('Spectrum (FFT)');

  const _BandView(this.label);

  final String label;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, this.child, this.trailing, this.onHeaderTap});

  final String title;

  /// Null shows the header alone (a folded card).
  final Widget? child;
  final Widget? trailing;

  /// Makes the header a button, for cards that fold.
  final VoidCallback? onHeaderTap;

  Widget _header() {
    final row = Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink),
          ),
        ),
        ?trailing,
      ],
    );
    final tap = onHeaderTap;
    if (tap == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: tap, child: row),
    );
  }

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
          _header(),
          if (child != null) ...[const SizedBox(height: 14), child!],
        ],
      ),
    ),
  );
}

/// "Show ⌄" / "Hide ⌃" for a folding card's header.
class _FoldLabel extends StatelessWidget {
  const _FoldLabel({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        open ? 'Hide' : 'Show',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted),
      ),
      const SizedBox(width: 2),
      Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: _muted),
    ],
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

/// Which EEG channels band power or the ERP is averaged over, or, for the
/// ERP, a cup's top electrode minus its bottom one (see [Mw75Montage]).
class _ChannelSet {
  const _ChannelSet.all() : side = null, channel = null, bipolar = false;
  const _ChannelSet.side(EarSide this.side) : channel = null, bipolar = false;
  const _ChannelSet.channel(int this.channel) : side = null, bipolar = false;

  /// Top minus bottom on one cup, or ([side] null) on both cups averaged.
  const _ChannelSet.bipolar([this.side]) : channel = null, bipolar = true;

  final EarSide? side;
  final int? channel;
  final bool bipolar;

  List<int> get channels => switch ((side, channel, bipolar)) {
    (_, final int c, _) => [c],
    (EarSide.left, _, true) => [Mw75Montage.leftTop],
    (EarSide.right, _, true) => [Mw75Montage.rightTop],
    (null, _, true) => [Mw75Montage.leftTop, Mw75Montage.rightTop],
    (EarSide.left, _, _) => [0, 1, 2, 3, 4, 5],
    (EarSide.right, _, _) => [6, 7, 8, 9, 10, 11],
    _ => List.generate(Mw75Protocol.eegChannelCount, (i) => i),
  };

  /// Subtracted from [channels]; empty unless [bipolar].
  List<int> get minus => switch ((side, bipolar)) {
    (EarSide.left, true) => [Mw75Montage.leftBottom],
    (EarSide.right, true) => [Mw75Montage.rightBottom],
    (null, true) => [Mw75Montage.leftBottom, Mw75Montage.rightBottom],
    _ => const [],
  };

  String get label => switch ((side, channel, bipolar)) {
    (_, final int c, _) => 'Ch${c + 1}',
    (EarSide.left, _, true) => 'Left top − bottom (Ch2 − Ch5)',
    (EarSide.right, _, true) => 'Right top − bottom (Ch8 − Ch11)',
    (null, _, true) => 'Both cups, top − bottom',
    (EarSide.left, _, _) => 'Left cup (Ch1–6)',
    (EarSide.right, _, _) => 'Right cup (Ch7–12)',
    _ => 'All EEG channels',
  };

  static final options = [
    const _ChannelSet.all(),
    const _ChannelSet.side(EarSide.left),
    const _ChannelSet.side(EarSide.right),
    for (var c = 0; c < Mw75Protocol.eegChannelCount; c++) _ChannelSet.channel(c),
  ];

  /// For the ERP: the bipolar pairs first, the pre-chosen main measure.
  static final erpOptions = [
    const _ChannelSet.bipolar(),
    const _ChannelSet.bipolar(EarSide.left),
    const _ChannelSet.bipolar(EarSide.right),
    ...options,
  ];

  @override
  bool operator ==(Object other) =>
      other is _ChannelSet && other.side == side && other.channel == channel && other.bipolar == bipolar;

  @override
  int get hashCode => Object.hash(side, channel, bipolar);
}

class _ChannelSetPicker extends StatelessWidget {
  const _ChannelSetPicker({required this.value, required this.onChanged, this.erp = false});

  final _ChannelSet value;
  final ValueChanged<_ChannelSet> onChanged;

  /// Offer the ERP's bipolar pairs too.
  final bool erp;

  // The ⓘ beside it explains what each choice measures.
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _Picker<_ChannelSet>(
        value: value,
        options: erp ? _ChannelSet.erpOptions : _ChannelSet.options,
        label: (o) => o.label,
        tooltip: 'Channels to average',
        onChanged: onChanged,
      ),
      const MontageInfoButton(),
    ],
  );
}

/// A compact menu button for card headers.
class _Picker<T> extends StatelessWidget {
  const _Picker({
    required this.value,
    required this.options,
    required this.label,
    required this.tooltip,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) label;
  final String tooltip;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: tooltip,
    initialValue: value,
    onSelected: onChanged,
    position: PopupMenuPosition.under,
    itemBuilder: (context) => [
      for (final o in options)
        PopupMenuItem(
          value: o,
          height: 32,
          child: Text(label(o), style: const TextStyle(fontSize: 12)),
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
            label(value),
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
