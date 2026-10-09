import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'band_power.dart';
import 'headset.dart';
import 'lsl_eeg_outlet.dart';
import 'protocol.dart';
import 'stream_processor.dart';
import 'test_runs.dart';
import 'tone_output.dart';

/// Eyes-open / eyes-closed blocks. Closing the eyes raises 8–13 Hz (alpha)
/// power over much of the head within a couple of seconds, the oldest and
/// most robust check that a device records brain activity.
@immutable
class AlphaSettings {
  const AlphaSettings({this.blocksPerCondition = 6, this.blockSeconds = 20, this.settleSeconds = 4});

  /// Blocks of each kind, alternating and starting eyes open. Six of each
  /// lets the block-level permutation test reach p ≈ 0.002.
  final int blocksPerCondition;
  final double blockSeconds;

  /// Skipped at the start of each block: the spoken cue, the reaction to it
  /// and alpha settling to its new level.
  final double settleSeconds;

  Duration get duration => Duration(seconds: (2 * blocksPerCondition * blockSeconds).round());

  AlphaSettings copyWith({int? blocksPerCondition}) => AlphaSettings(
    blocksPerCondition: blocksPerCondition ?? this.blocksPerCondition,
    blockSeconds: blockSeconds,
    settleSeconds: settleSeconds,
  );

  Map<String, Object?> toJson() => {
    'blocksPerCondition': blocksPerCondition,
    'blockSeconds': blockSeconds,
    'settleSeconds': settleSeconds,
  };

  factory AlphaSettings.fromJson(Map<String, Object?> j) => AlphaSettings(
    blocksPerCondition: (j['blocksPerCondition'] as num?)?.toInt() ?? 6,
    blockSeconds: (j['blockSeconds'] as num?)?.toDouble() ?? 20,
    settleSeconds: (j['settleSeconds'] as num?)?.toDouble() ?? 4,
  );
}

/// The spectrum of one ~1 s stretch of EEG.
class AlphaWindow {
  const AlphaWindow({required this.start, required this.end, required this.psd, required this.alpha});

  /// LSL times of the first and last sample.
  final double start;
  final double end;

  /// Per channel, µV²/Hz from 0 Hz up to [AlphaWindowAnalyzer.maxHz].
  final List<Float64List> psd;

  /// Per channel, 8–13 Hz power in µV².
  final Float64List alpha;

  double get centre => (start + end) / 2;
}

/// Spectra of the live EEG in 512-sample windows every 256 samples (~1 s
/// windows, half overlapping). Windows with a Bluetooth dropout, a gap in the
/// timestamps or more than [maxLostFraction] interpolated samples are skipped:
/// interpolation is a straight line, which has no alpha in it.
class AlphaWindowAnalyzer {
  AlphaWindowAnalyzer({this.channelCount = Mw75Protocol.eegChannelCount});

  static const size = SegmentSpectrum.size;
  static const hop = 256;
  static const maxHz = 40.0;
  static const maxLostFraction = 0.3;
  static const _maxGap = 0.1;

  final int channelCount;
  final _times = <double>[];
  final _status = <int>[];
  late final _channels = List.generate(channelCount, (_) => <double>[]);
  final _spectrum = SegmentSpectrum();
  int _sinceLast = 0;

  /// Bins per stored spectrum at [sampleRate].
  static int binsFor(double sampleRate) => (maxHz / (sampleRate / size)).floor() + 1;

  List<AlphaWindow> add(List<Mw75Sample> samples, {required double sampleRate}) {
    final out = <AlphaWindow>[];
    for (final s in samples) {
      _times.add(s.time);
      _status.add(s.status);
      for (var c = 0; c < channelCount; c++) {
        _channels[c].add(s.values[c]);
      }
      if (++_sinceLast >= hop && _times.length >= size) {
        _sinceLast = 0;
        final w = _analyse(sampleRate);
        if (w != null) out.add(w);
      }
    }
    final excess = _times.length - size;
    if (excess > 4 * size) {
      _times.removeRange(0, excess);
      _status.removeRange(0, excess);
      for (final c in _channels) {
        c.removeRange(0, excess);
      }
    }
    return out;
  }

  void clear() {
    _times.clear();
    _status.clear();
    for (final c in _channels) {
      c.clear();
    }
    _sinceLast = 0;
  }

  AlphaWindow? _analyse(double sampleRate) {
    final start = _times.length - size;
    var lost = 0;
    for (var i = start; i < _times.length; i++) {
      if (_status[i] == SampleStatus.afterLongDropout) return null;
      if (i > start && _times[i] - _times[i - 1] > _maxGap) return null;
      if (_status[i] == SampleStatus.interpolated) lost++;
    }
    if (lost > maxLostFraction * size) return null;
    final binHz = sampleRate / size;
    final bins = binsFor(sampleRate);
    final psd = <Float64List>[];
    final alpha = Float64List(channelCount);
    for (var c = 0; c < channelCount; c++) {
      final full = _spectrum.psd(_channels[c], start, sampleRate);
      psd.add(Float64List.sublistView(Float64List.fromList(full), 0, bins));
      alpha[c] = bandPower(full, binHz, EegBand.alpha.low, EegBand.alpha.high);
    }
    return AlphaWindow(start: _times[start], end: _times.last, psd: psd, alpha: alpha);
  }
}

/// Power in [low, high) Hz from a density spectrum with bins [binHz] apart.
double bandPower(List<double> psd, double binHz, double low, double high) {
  var sum = 0.0;
  for (var k = 0; k < psd.length; k++) {
    final f = k * binHz;
    if (f >= low && f < high) sum += psd[k] * binHz;
  }
  return sum;
}

/// One eyes-open or eyes-closed block and the windows analysed in it.
class AlphaBlock {
  AlphaBlock({required this.eyesClosed, required this.cue, required int bins, int channels = Mw75Protocol.eegChannelCount})
    : spectrumSum = List.generate(channels, (_) => Float64List(bins));

  final bool eyesClosed;

  /// LSL time of the spoken cue that started it.
  final double cue;

  /// LSL time it ended (the next cue), once known.
  double? end;

  final windowTimes = <double>[];

  /// Per window, 8–13 Hz power per channel (µV²).
  final windowAlpha = <Float64List>[];

  /// Per channel, the sum of the window spectra.
  final List<Float64List> spectrumSum;

  int get windows => windowTimes.length;

  void add(AlphaWindow w) {
    windowTimes.add(w.centre);
    windowAlpha.add(w.alpha);
    for (var c = 0; c < spectrumSum.length; c++) {
      final sum = spectrumSum[c];
      final psd = w.psd[c];
      for (var k = 0; k < sum.length && k < psd.length; k++) {
        sum[k] += psd[k];
      }
    }
  }

  Map<String, Object?> toJson() => {
    'eyesClosed': eyesClosed,
    'cue': cue,
    'end': end,
    'windowTimes': windowTimes,
    'windowAlphaUv2': [
      for (final a in windowAlpha) [for (final v in a) round3(v)],
    ],
    'meanSpectrumUv2PerHz': [
      for (final s in spectrumSum) [for (final v in s) windows == 0 ? 0.0 : round3(v / windows)],
    ],
  };

  factory AlphaBlock.fromJson(Map<String, Object?> j) {
    final spectra = (j['meanSpectrumUv2PerHz'] as List).cast<List<Object?>>();
    final block = AlphaBlock(
      eyesClosed: j['eyesClosed'] as bool,
      cue: (j['cue'] as num).toDouble(),
      bins: spectra.isEmpty ? 0 : spectra.first.length,
      channels: spectra.length,
    )..end = (j['end'] as num?)?.toDouble();
    block.windowTimes.addAll([for (final t in j['windowTimes'] as List) (t as num).toDouble()]);
    block.windowAlpha.addAll([
      for (final a in (j['windowAlphaUv2'] as List).cast<List<Object?>>())
        Float64List.fromList([for (final v in a) (v as num).toDouble()]),
    ]);
    for (var c = 0; c < spectra.length; c++) {
      for (var k = 0; k < spectra[c].length; k++) {
        block.spectrumSum[c][k] = (spectra[c][k] as num).toDouble() * block.windows;
      }
    }
    return block;
  }
}

/// One run of the alpha test, live or loaded from disk.
class AlphaRun {
  AlphaRun({required this.started, required this.settings, required this.binHz, this.included = true});

  static const kind = 'alpha';

  final DateTime started;
  final AlphaSettings settings;

  /// Spacing of the spectrum bins, Hz.
  final double binHz;
  final blocks = <AlphaBlock>[];

  /// Every analysed window, in or between blocks: (LSL time, alpha per channel).
  final timeline = <(double, Float64List)>[];
  bool included;
  String? folder;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'version': 1,
    'started': started.toIso8601String(),
    'settings': settings.toJson(),
    'binHz': binHz,
    'alphaBandHz': [EegBand.alpha.low, EegBand.alpha.high],
    'blocks': [for (final b in blocks) b.toJson()],
    'timeline': [
      for (final (t, a) in timeline) [t, for (final v in a) round3(v)],
    ],
  };

  factory AlphaRun.fromJson(Map<String, Object?> j, {required String folder}) {
    final run = AlphaRun(
      started: DateTime.parse(j['started'] as String),
      settings: AlphaSettings.fromJson((j['settings'] as Map).cast<String, Object?>()),
      binHz: (j['binHz'] as num).toDouble(),
      included: false,
    )..folder = folder;
    run.blocks.addAll([
      for (final b in (j['blocks'] as List).cast<Map<Object?, Object?>>()) AlphaBlock.fromJson(b.cast<String, Object?>()),
    ]);
    for (final row in (j['timeline'] as List? ?? const []).cast<List<Object?>>()) {
      run.timeline.add((
        (row.first as num).toDouble(),
        Float64List.fromList([for (final v in row.skip(1)) (v as num).toDouble()]),
      ));
    }
    return run;
  }
}

/// Alpha with eyes open vs closed for one set of channels.
class AlphaSummary {
  AlphaSummary._({
    required this.binHz,
    required this.openSpectrum,
    required this.closedSpectrum,
    required this.openBlocks,
    required this.closedBlocks,
    required this.ratio,
    required this.p,
    required this.peakHz,
  });

  /// Fewest windows (~0.5 s apart) for a block to count.
  static const minWindows = 5;

  /// Fewest blocks of each kind before the test runs.
  static const minBlocks = 3;

  /// For each block, the median over its windows of log10 alpha power
  /// (averaged over [channels]); the median shrugs off the odd movement
  /// artifact. The ratio compares the mean of those between eyes closed and
  /// open. The test permutes the open/closed labels across blocks (all
  /// arrangements when there are few enough), since windows within a block
  /// are not independent.
  factory AlphaSummary.compute(List<AlphaBlock> blocks, List<int> channels, {required double binHz}) {
    final open = <double>[];
    final closed = <double>[];
    Float64List? openSum, closedSum;
    var openWindows = 0, closedWindows = 0;
    for (final b in blocks) {
      if (b.windows < minWindows) continue;
      final values = [
        for (final a in b.windowAlpha) math.log(channels.fold(0.0, (s, c) => s + a[c]) / channels.length) / math.ln10,
      ];
      (b.eyesClosed ? closed : open).add(_median(values));
      final bins = b.spectrumSum.first.length;
      final sum = b.eyesClosed ? (closedSum ??= Float64List(bins)) : (openSum ??= Float64List(bins));
      for (final c in channels) {
        for (var k = 0; k < math.min(bins, sum.length); k++) {
          sum[k] += b.spectrumSum[c][k];
        }
      }
      if (b.eyesClosed) {
        closedWindows += b.windows;
      } else {
        openWindows += b.windows;
      }
    }
    Float64List? mean(Float64List? sum, int windows) =>
        sum == null ? null : Float64List.fromList([for (final v in sum) v / windows / channels.length]);
    final openSpectrum = mean(openSum, openWindows);
    final closedSpectrum = mean(closedSum, closedWindows);

    double? ratio, p, peakHz;
    if (open.isNotEmpty && closed.isNotEmpty) {
      ratio = math.pow(10, _mean(closed) - _mean(open)).toDouble();
      if (open.length >= minBlocks && closed.length >= minBlocks) p = _permutationP(closed, open);
      // Where closing the eyes raises power the most, between 7 and 14 Hz.
      var best = 0.0;
      for (var k = 0; k < math.min(openSpectrum!.length, closedSpectrum!.length); k++) {
        final f = k * binHz;
        if (f < 7 || f > 14 || openSpectrum[k] <= 0) continue;
        final gain = closedSpectrum[k] / openSpectrum[k];
        if (gain > best) {
          best = gain;
          peakHz = f;
        }
      }
    }
    return AlphaSummary._(
      binHz: binHz,
      openSpectrum: openSpectrum,
      closedSpectrum: closedSpectrum,
      openBlocks: open.length,
      closedBlocks: closed.length,
      ratio: ratio,
      p: p,
      peakHz: peakHz,
    );
  }

  final double binHz;

  /// Mean density (µV²/Hz) per bin over the eyes-open / eyes-closed windows.
  final Float64List? openSpectrum;
  final Float64List? closedSpectrum;
  final int openBlocks;
  final int closedBlocks;

  /// Alpha power with eyes closed ÷ eyes open (geometric).
  final double? ratio;

  /// Two-sided permutation p-value, once there are [minBlocks] of each.
  final double? p;

  /// Frequency (7–14 Hz) where eyes closed raised power the most.
  final double? peakHz;

  static double _mean(List<double> v) => v.fold(0.0, (a, b) => a + b) / v.length;

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  /// Exact when there are at most 20,000 arrangements, else 20,000 random ones.
  static double _permutationP(List<double> closed, List<double> open) {
    final all = [...closed, ...open];
    final n = all.length;
    final k = closed.length;
    final total = all.fold(0.0, (a, b) => a + b);
    double diff(double closedSum) => closedSum / k - (total - closedSum) / (n - k);
    final observed = diff(closed.fold(0.0, (a, b) => a + b)).abs() - 1e-12;

    var combinations = 1.0;
    for (var i = 0; i < k; i++) {
      combinations = combinations * (n - i) / (i + 1);
    }
    if (combinations <= 20000) {
      var hits = 0, count = 0;
      void choose(int from, int left, double sum) {
        if (left == 0) {
          count++;
          if (diff(sum).abs() >= observed) hits++;
          return;
        }
        for (var i = from; i <= n - left; i++) {
          choose(i + 1, left - 1, sum + all[i]);
        }
      }

      choose(0, k, 0);
      return hits / count;
    }
    final random = math.Random(1);
    final pool = [...all];
    var hits = 0;
    const permutations = 20000;
    for (var p = 0; p < permutations; p++) {
      var sum = 0.0;
      for (var i = 0; i < k; i++) {
        final j = i + random.nextInt(n - i);
        final t = pool[i];
        pool[i] = pool[j];
        pool[j] = t;
        sum += pool[i];
      }
      if (diff(sum).abs() >= observed) hits++;
    }
    return (hits + 1) / (permutations + 1);
  }
}

enum AlphaState { idle, preparing, running, finishing }

/// Runs the eyes-open / eyes-closed test against the live EEG, with spoken
/// cues so it works with the eyes shut.
class AlphaSession extends ChangeNotifier {
  AlphaSession({required this.headset, ToneOutput? voice, this.store}) : _voice = voice ?? ToneOutput();

  /// Below this recent packet loss the EEG link counts as settled.
  static const _maxLossToStart = 0.6;

  final Mw75Headset headset;
  final ToneOutput _voice;

  /// Where runs are saved; null keeps them in memory only.
  final TestRunStore? store;

  AlphaState _state = AlphaState.idle;
  AlphaState get state => _state;
  bool get busy => _state != AlphaState.idle;
  String statusText = 'Start raw EEG, then start the test.';

  AlphaSettings _settings = const AlphaSettings();
  AlphaSettings get settings => _settings;
  set settings(AlphaSettings value) {
    _settings = value;
    notifyListeners();
  }

  /// This session's runs and any loaded from disk, newest first.
  final runs = <AlphaRun>[];

  /// The run in progress, or null.
  AlphaRun? get current => _current;

  /// Blocks of the included runs.
  List<AlphaBlock> get blocks => [
    for (final r in runs)
      if (r.included) ...r.blocks,
  ];

  /// The run whose timeline to show: the one in progress, else the newest
  /// included one.
  AlphaRun? get shownRun => _current ?? runs.where((r) => r.included).firstOrNull;

  /// While running: whether eyes should be closed now, and when the block ends.
  bool? get eyesClosedNow => busy ? _current?.blocks.lastOrNull?.eyesClosed : null;
  double? blockEndsAt;
  int get blockNumber => _current?.blocks.length ?? 0;
  int get blockCount => 2 * _settings.blocksPerCondition;

  /// Ticks twice a second during a run, for countdowns and plots.
  Listenable get progress => _progress;
  final _progress = _Ticker();

  final _analyzer = AlphaWindowAnalyzer();
  StreamSubscription<List<Mw75Sample>>? _samples;
  AlphaRun? _current;
  RunRecorder? _recorder;
  Timer? _progressTimer;
  int _run = 0;

  AlphaSummary summary(List<int> channels) =>
      AlphaSummary.compute(blocks, channels, binHz: runs.where((r) => r.included).firstOrNull?.binHz ?? 500 / 512);

  Future<void> loadSaved() async {
    final store = this.store;
    if (store == null) return;
    try {
      final known = {for (final r in runs) r.folder};
      for (final (folder, json) in await store.load(AlphaRun.kind)) {
        if (known.contains(folder)) continue;
        try {
          runs.add(AlphaRun.fromJson(json, folder: folder));
        } catch (e) {
          debugPrint('[alpha] could not read $folder: $e');
        }
      }
      runs.sort((a, b) => b.started.compareTo(a.started));
    } catch (e) {
      debugPrint('[alpha] could not list saved runs: $e');
    }
    notifyListeners();
  }

  void setIncluded(AlphaRun run, bool included) {
    run.included = included;
    notifyListeners();
  }

  /// Takes every run out of the results. Saved runs stay on disk.
  void clearResults() {
    for (final r in runs) {
      r.included = false;
    }
    notifyListeners();
  }

  Future<void> start() async {
    if (busy) return;
    if (headset.state != HeadsetState.streaming) {
      statusText = 'Start raw EEG first.';
      notifyListeners();
      return;
    }
    final run = ++_run;
    final settings = _settings;
    final rate = headset.effectiveRate ?? Mw75Protocol.samplingRate;
    final current = AlphaRun(started: DateTime.now(), settings: settings, binHz: rate / AlphaWindowAnalyzer.size);
    _current = current;
    runs.insert(0, current);
    _setState(AlphaState.preparing, 'Getting ready…');
    try {
      _recorder = await store?.begin(AlphaRun.kind, current.started);
    } catch (e) {
      debugPrint('[alpha] not saving this run: $e');
    }
    if (run != _run) {
      runs.remove(current);
      await _recorder?.discard();
      _recorder = null;
      _current = null;
      return;
    }
    _analyzer.clear();
    _samples = headset.samples.listen((s) => _onSamples(s, rate));
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _progress.tick());

    unawaited(_say('Keep your eyes open and look at one spot. The test starts in a few seconds.'));
    final ready = LslEegOutlet.localClock() + 6;
    if (!await _waitUntil(ready, run)) return;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while ((headset.recentLossRatio ?? 1) > _maxLossToStart && DateTime.now().isBefore(deadline)) {
      _setStatus('Waiting for the EEG link to settle…');
      if (!await _waitUntil(LslEegOutlet.localClock() + 0.5, run)) return;
    }

    _setState(AlphaState.running, '');
    for (var i = 0; i < 2 * settings.blocksPerCondition; i++) {
      final closed = i.isOdd;
      final cue = LslEegOutlet.localClock();
      current.blocks.lastOrNull?.end = cue;
      current.blocks.add(
        AlphaBlock(eyesClosed: closed, cue: cue, bins: AlphaWindowAnalyzer.binsFor(rate)),
      );
      blockEndsAt = cue + settings.blockSeconds;
      unawaited(_say(closed ? 'Close your eyes.' : (i == 0 ? 'Eyes open.' : 'Open your eyes.')));
      _setStatus(closed ? 'Eyes closed. Relax and keep still.' : 'Eyes open. Look at one spot and relax.');
      if (!await _waitUntil(blockEndsAt!, run)) return;
    }
    current.blocks.last.end = LslEegOutlet.localClock();
    unawaited(_say('Done. You can open your eyes.'));
    _setState(AlphaState.finishing, 'Collecting the last of the EEG…');
    // Samples reach the app a few hundred milliseconds after they are taken.
    if (!await _waitUntil(LslEegOutlet.localClock() + 1.5, run)) return;
    final s = AlphaSummary.compute(current.blocks, List.generate(Mw75Protocol.eegChannelCount, (i) => i), binHz: current.binHz);
    await _end(
      run,
      s.ratio == null
          ? 'Done.'
          : 'Done: alpha ×${s.ratio!.toStringAsFixed(2)} with eyes closed, averaged over all channels.',
    );
  }

  Future<void> stop() async {
    if (!busy) return;
    unawaited(_say('Test stopped. You can open your eyes.'));
    await _end(_run, 'Stopped after $blockNumber of $blockCount blocks.');
  }

  @override
  void dispose() {
    _run++;
    _progressTimer?.cancel();
    _samples?.cancel();
    unawaited(_recorder?.discard());
    _progress.dispose();
    super.dispose();
  }

  /// Waits until LSL time [t]. False if the run was stopped or the EEG
  /// stopped meanwhile (which ends the run).
  Future<bool> _waitUntil(double t, int run) async {
    while (LslEegOutlet.localClock() < t) {
      if (run != _run) return false;
      if (headset.state != HeadsetState.streaming) {
        unawaited(_say('The test stopped. You can open your eyes.'));
        await _end(run, 'Raw EEG stopped, so the test stopped after $blockNumber of $blockCount blocks.');
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return run == _run;
  }

  Future<void> _end(int run, String message) async {
    if (run != _run) return;
    _run++;
    _progressTimer?.cancel();
    _progressTimer = null;
    await _samples?.cancel();
    _samples = null;
    blockEndsAt = null;
    final current = _current;
    final recorder = _recorder;
    _current = null;
    _recorder = null;
    if (current != null) {
      current.blocks.lastOrNull?.end ??= LslEegOutlet.localClock();
      if (current.timeline.isEmpty) runs.remove(current);
    }
    var status = message;
    if (current != null && recorder != null) {
      try {
        if (current.timeline.isEmpty) {
          await recorder.discard();
        } else {
          await recorder.finish(current.toJson());
          current.folder = recorder.folder.path;
          status = '$message Saved.';
        }
      } catch (e) {
        status = '$message Could not save the run: $e';
      }
    }
    _progress.tick();
    _setState(AlphaState.idle, status);
  }

  void _onSamples(List<Mw75Sample> samples, double rate) {
    _recorder?.addSamples(samples);
    final current = _current;
    if (current == null) return;
    for (final w in _analyzer.add(samples, sampleRate: rate)) {
      current.timeline.add((w.centre, w.alpha));
      final block = current.blocks.lastWhere((b) => b.cue <= w.start, orElse: () => _noBlock);
      if (identical(block, _noBlock)) continue;
      final end = block.end;
      if (w.start < block.cue + current.settings.settleSeconds || (end != null && w.end > end)) continue;
      block.add(w);
    }
  }

  static final _noBlock = AlphaBlock(eyesClosed: false, cue: 0, bins: 0, channels: 0);

  Future<void> _say(String text) => _voice.speak(text).catchError((Object e) => debugPrint('[alpha] speech failed: $e'));

  void _setState(AlphaState state, String status) {
    _state = state;
    statusText = status;
    notifyListeners();
  }

  void _setStatus(String status) {
    statusText = status;
    notifyListeners();
  }
}

class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
}
