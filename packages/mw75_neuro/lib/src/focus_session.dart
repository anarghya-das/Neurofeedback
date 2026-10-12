import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'focus_metric.dart';
import 'headset.dart';
import 'lsl_eeg_outlet.dart';
import 'protocol.dart';
import 'signal_quality.dart';
import 'stream_processor.dart';
import 'test_runs.dart';
import 'tone_output.dart';

/// Calibration blocks: alternating rest and focus, starting with rest.
@immutable
class FocusCalibrationSettings {
  const FocusCalibrationSettings({this.blocksPerCondition = 4, this.blockSeconds = 30, this.settleSeconds = 5});

  final int blocksPerCondition;
  final double blockSeconds;

  /// Skipped at the start of each block: the spoken cue and settling in.
  final double settleSeconds;

  Duration get duration => Duration(seconds: (2 * blocksPerCondition * blockSeconds).round());

  FocusCalibrationSettings copyWith({int? blocksPerCondition}) => FocusCalibrationSettings(
    blocksPerCondition: blocksPerCondition ?? this.blocksPerCondition,
    blockSeconds: blockSeconds,
    settleSeconds: settleSeconds,
  );
}

/// One point of the live focus history.
class FocusPoint {
  const FocusPoint(this.time, this.score, {required this.noisy, this.target});

  /// LSL time.
  final double time;

  /// Smoothed score 0–100, or null before the first clean window.
  final double? score;
  final bool noisy;

  /// The feedback target at the time, 0–100.
  final double? target;
}

enum FocusState { idle, preparing, calibrating, finishing }

/// A personal focus score from the raw EEG.
///
/// Calibration alternates "rest" (relax, eyes on a dot, mind wandering) with
/// "focus" (silently counting backwards in sevens, a standard mental workload
/// task), with spoken cues, and trains a [FocusModel] on those windows. Once
/// calibrated, every ~0.5 s the latest 2 s of EEG are scored, smoothed and
/// published as the "MW75 Focus" LSL stream. The score means "how much your
/// EEG now resembles your own focused calibration blocks": it is personal,
/// and only as good as its cross-validated accuracy.
class FocusSession extends ChangeNotifier {
  FocusSession({required this.headset, ToneOutput? voice, this.store, this.publishToLsl = true})
    : _voice = voice ?? ToneOutput() {
    _samples = headset.samples.listen(_onSamples);
  }

  static const lslName = 'MW75 Focus';

  /// Smoothing time constant of the score, seconds.
  static const smoothing = 4.0;

  /// Windows with more interpolated samples than this are not scored.
  static const maxLostFraction = 0.3;

  /// Below this held-out AUC the score is not much better than chance.
  static const minUsefulAuc = 0.65;

  static const _history = 600.0;

  /// The feedback target is the [targetPercentile] of the clean scores of the
  /// last [targetSpan] seconds, recomputed every [targetEvery] seconds and kept
  /// within [targetRange], so the score clears it about 70% of the time:
  /// within the 60–80% success rate usually advised for neurofeedback.
  /// Recomputing it in steps, not continuously, keeps the reward contingent on
  /// doing better than a moment ago; the floor keeps rest-like EEG from being
  /// rewarded however low the scores have been.
  static const targetPercentile = 0.3;
  static const targetSpan = 180.0;
  static const targetEvery = 60.0;
  static const targetRange = (40.0, 85.0);

  /// Calibration waits (up to 30 s) for the Bluetooth link to lose less
  /// than this: blocks recorded while it settles are mostly filled-in data.
  static const _maxLossToStart = 0.3;

  final Mw75Headset headset;
  final ToneOutput _voice;
  final TestRunStore? store;
  final bool publishToLsl;

  FocusState _state = FocusState.idle;
  FocusState get state => _state;
  bool get calibrating => _state != FocusState.idle;
  String statusText = 'Calibrate to create your focus score.';

  FocusCalibrationSettings _settings = const FocusCalibrationSettings();
  FocusCalibrationSettings get settings => _settings;
  set settings(FocusCalibrationSettings value) {
    _settings = value;
    notifyListeners();
  }

  /// The trained model, from this session or loaded from disk.
  FocusModel? model;

  /// During calibration: whether this block is a focus block, the number to
  /// count back from, and when the block ends (LSL time).
  bool? focusBlockNow;
  int? countFrom;
  double? blockEndsAt;
  int blockNumber = 0;
  int get blockCount => 2 * _settings.blocksPerCondition;

  /// Live output: smoothed score 0–100 and whether the latest window was too
  /// noisy to score.
  double? score;
  bool noisy = false;
  final history = <FocusPoint>[];

  /// The personal feedback target, 0–100 (see [targetPercentile]).
  double target = 50;

  /// Since calibrating or loading the model: seconds scored, and seconds the
  /// score was at or above [target].
  double scoredSeconds = 0;
  double secondsAboveTarget = 0;

  bool get aboveTarget => !noisy && (score ?? 0) >= target;

  /// The latest window's share of samples filled in for Bluetooth losses, and
  /// whether its power was beyond the calibration's artifact limits.
  double? lastLostFraction;
  bool lastArtifact = false;

  /// Why the latest window was not scored, or null when it was.
  String? get noisyReason {
    if (!noisy) return null;
    final reasons = <String>[];
    final lost = lastLostFraction ?? 0;
    if (lost > maxLostFraction) {
      reasons.add(
        '${(lost * 100).round()}% of the EEG was lost over Bluetooth '
        '(scoring needs under ${(maxLostFraction * 100).round()}%)',
      );
    }
    if (lastArtifact) reasons.add('the EEG is far stronger than in calibration (movement, jaw or poor contact)');
    final bad = headset.quality?.channels.where((q) => q == ContactQuality.bad).length ?? 0;
    if (bad > 0) reasons.add('$bad of ${Mw75Protocol.eegChannelCount} channels report bad contact');
    if (reasons.isEmpty) return null;
    final text = reasons.join('; ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }

  /// Ticks twice a second during calibration, for countdowns.
  Listenable get progress => _progress;
  final _progress = _Ticker();

  final _extractor = FocusFeatureExtractor();
  final _random = math.Random();
  late final StreamSubscription<List<Mw75Sample>> _samples;
  _Calibration? _calibration;
  RunRecorder? _recorder;
  LslEegOutlet? _outlet;
  Timer? _progressTimer;
  double? _lastScored;
  double? _targetSetAt;
  int _run = 0;

  File? get _modelFile => store == null ? null : File('${store!.directory.path}/focus model.json');

  /// Loads the last saved model, if any.
  Future<void> loadSaved() async {
    final file = _modelFile;
    if (file == null || !await file.exists()) return;
    try {
      model = FocusModel.fromJson((jsonDecode(await file.readAsString()) as Map).cast<String, Object?>());
      statusText = 'Using your calibration from ${_date(model!.created)}. Recalibrate if the fit or the day differs.';
    } on FormatException {
      statusText = 'Your saved calibration is from an earlier version of the focus score. Recalibrate to use it.';
    } catch (e) {
      debugPrint('[focus] could not read the saved model: $e');
    }
    notifyListeners();
  }

  Future<void> calibrate() async {
    if (calibrating) return;
    if (headset.state != HeadsetState.streaming) {
      statusText = 'Start raw EEG first.';
      notifyListeners();
      return;
    }
    final run = ++_run;
    final settings = _settings;
    final started = DateTime.now();
    final calibration = _Calibration(settings);
    _calibration = calibration;
    blockNumber = 0;
    _setState(FocusState.preparing, 'Getting ready…');
    try {
      _recorder = await store?.begin('focus-calibration', started);
    } catch (e) {
      debugPrint('[focus] not saving this calibration: $e');
    }
    if (run != _run) {
      await _recorder?.discard();
      _recorder = null;
      return;
    }
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _progress.tick());

    unawaited(
      _say(
        'Calibration. Sit comfortably, keep your jaw relaxed and your eyes on the dot. '
        'It starts in a few seconds.',
      ),
    );
    if (!await _waitUntil(LslEegOutlet.localClock() + 10, run)) return;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while ((headset.recentLossRatio ?? 1) > _maxLossToStart && DateTime.now().isBefore(deadline)) {
      _setStatus('Waiting for the EEG link to settle…');
      if (!await _waitUntil(LslEegOutlet.localClock() + 0.5, run)) return;
    }

    _setState(FocusState.calibrating, '');
    for (var i = 0; i < 2 * settings.blocksPerCondition; i++) {
      final focus = i.isOdd;
      final cue = LslEegOutlet.localClock();
      calibration.startBlock(focus: focus, cue: cue);
      blockNumber = i + 1;
      focusBlockNow = focus;
      blockEndsAt = cue + settings.blockSeconds;
      if (focus) {
        // A fresh three-digit start each time, so the counting stays effortful.
        countFrom = 300 + _random.nextInt(700);
        unawaited(_say('Focus. Count backwards from $countFrom in sevens, silently.'));
        _setStatus('Count backwards from $countFrom in sevens, silently. Keep your eyes on the dot.');
      } else {
        countFrom = null;
        unawaited(_say('Relax. Let your mind wander, eyes on the dot.'));
        _setStatus('Relax and let your mind wander. Keep your eyes on the dot.');
      }
      if (!await _waitUntil(blockEndsAt!, run)) return;
    }
    calibration.endLastBlock(LslEegOutlet.localClock());
    unawaited(_say('Calibration done.'));
    _setState(FocusState.finishing, 'Training your focus model…');
    // Samples reach the app a few hundred milliseconds after they are taken.
    if (!await _waitUntil(LslEegOutlet.localClock() + 1.5, run)) return;
    await _finish(run, started);
  }

  Future<void> stop() async {
    if (!calibrating) return;
    unawaited(_say('Calibration stopped.'));
    await _end(_run, 'Calibration stopped. ${model == null ? '' : 'The previous calibration is still in use.'}');
  }

  @override
  void dispose() {
    _run++;
    _progressTimer?.cancel();
    _samples.cancel();
    unawaited(_recorder?.discard());
    _outlet?.close();
    _progress.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  Future<void> _finish(int run, DateTime started) async {
    final calibration = _calibration!;
    final focusBlocks = [
      for (final b in calibration.blocks)
        if (b.focus) b.windows,
    ];
    final restBlocks = [
      for (final b in calibration.blocks)
        if (!b.focus) b.windows,
    ];
    final FocusModel trained;
    try {
      trained = FocusModel.train(focusBlocks: focusBlocks, restBlocks: restBlocks);
    } on StateError catch (e) {
      await _end(
        run,
        'Not enough clean EEG to calibrate: ${e.message} Check the fit and the Bluetooth link '
        '(the Headset card shows data loss), keep still, then try again.',
      );
      return;
    }
    model = trained;
    _resetScore();
    try {
      final file = _modelFile;
      if (file != null) {
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(trained.toJson()));
      }
      await _recorder?.finish({
        'kind': 'focus-calibration',
        'version': 1,
        'started': started.toIso8601String(),
        'settings': {
          'blocksPerCondition': calibration.settings.blocksPerCondition,
          'blockSeconds': calibration.settings.blockSeconds,
          'settleSeconds': calibration.settings.settleSeconds,
        },
        'blocks': [
          for (final b in calibration.blocks)
            {'focus': b.focus, 'cue': b.cue, 'end': b.end, 'windows': b.windows.length},
        ],
        'model': trained.toJson(),
      });
      _recorder = null;
    } catch (e) {
      debugPrint('[focus] could not save the calibration: $e');
    }
    final verdict = trained.cvAuc >= 0.75
        ? 'a good separation'
        : trained.cvAuc >= minUsefulAuc
        ? 'a fair separation'
        : 'too little separation for a reliable score';
    final leftOut = trained.blocksLeftOut == 0
        ? ''
        : ' ${trained.blocksLeftOut} block${trained.blocksLeftOut == 1 ? ' was' : 's were'} left out '
              '(data lost over Bluetooth or artifacts).';
    await _end(
      run,
      'Calibrated: ${(trained.cvAccuracy * 100).round()}% of held-out windows classified correctly '
      '(AUC ${trained.cvAuc.toStringAsFixed(2)}), $verdict.$leftOut',
    );
  }

  /// Waits until LSL time [t]. False if the calibration was stopped or the
  /// EEG stopped meanwhile (which ends it).
  Future<bool> _waitUntil(double t, int run) async {
    while (LslEegOutlet.localClock() < t) {
      if (run != _run) return false;
      if (headset.state != HeadsetState.streaming) {
        await _end(run, 'Raw EEG stopped, so the calibration stopped.');
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
    _calibration = null;
    focusBlockNow = null;
    countFrom = null;
    blockEndsAt = null;
    await _recorder?.discard();
    _recorder = null;
    _progress.tick();
    _setState(FocusState.idle, message);
  }

  void _onSamples(List<Mw75Sample> samples) {
    _recorder?.addSamples(samples);
    final rate = headset.effectiveRate ?? Mw75Protocol.samplingRate;
    for (final w in _extractor.add(samples, sampleRate: rate)) {
      final calibration = _calibration;
      if (calibration != null) {
        calibration.add(w);
      } else {
        _score(w);
      }
    }
  }

  void _score(FocusWindow w) {
    final m = model;
    if (m == null) return;
    lastLostFraction = w.lostFraction;
    lastArtifact = !m.isClean(w);
    noisy = w.lostFraction > maxLostFraction || lastArtifact;
    if (!noisy) {
      final target = 100 * m.probability(w.features);
      final last = _lastScored;
      final current = score;
      if (current == null || last == null) {
        score = target;
      } else {
        final dt = (w.end - last).clamp(0.0, 10.0);
        score = current + (target - current) * (1 - math.exp(-dt / smoothing));
      }
      if (last != null) {
        final dt = (w.end - last).clamp(0.0, 1.0);
        scoredSeconds += dt;
        if (score! >= target) secondsAboveTarget += dt;
      }
      _lastScored = w.end;
    }
    _updateTarget(w.end);
    history.add(FocusPoint(w.end, score, noisy: noisy, target: target));
    while (history.isNotEmpty && w.end - history.first.time > _history) {
      history.removeAt(0);
    }
    _publish(w.end);
    notifyListeners();
  }

  void _resetScore() {
    score = null;
    noisy = false;
    lastLostFraction = null;
    lastArtifact = false;
    _lastScored = null;
    history.clear();
    target = 50;
    _targetSetAt = null;
    scoredSeconds = 0;
    secondsAboveTarget = 0;
  }

  void _updateTarget(double now) {
    final setAt = _targetSetAt ??= now;
    if (now - setAt < targetEvery) return;
    _targetSetAt = now;
    target = targetFor(history, now) ?? target;
  }

  /// The target from the scores before [now], or null with less than about a
  /// minute of clean scores.
  static double? targetFor(Iterable<FocusPoint> history, double now) {
    final recent = [
      for (final p in history)
        if (!p.noisy && p.score != null && now - p.time <= targetSpan) p.score!,
    ]..sort();
    if (recent.length < 100) return null;
    final (low, high) = targetRange;
    return recent[(targetPercentile * (recent.length - 1)).round()].clamp(low, high);
  }

  void _publish(double time) {
    if (!publishToLsl) return;
    try {
      _outlet ??= LslEegOutlet.create(
        name: lslName,
        type: 'Focus',
        sourceId: 'mw75-focus',
        nominalRate: 0,
        extraDesc: const {
          'description':
              'Personal focus score from the MW75 raw EEG (calibrated rest vs mental arithmetic); '
              'about two values a second.',
        },
        channels: const [
          LslChannel('focus', unit: 'percent', type: 'Focus'),
          LslChannel('quality', unit: '1 clean, 0 too noisy to score', type: 'Quality'),
        ],
      );
      _outlet!.pushChunk(
        [
          [score ?? double.nan, noisy ? 0 : 1],
        ],
        [time],
      );
    } catch (e) {
      debugPrint('[focus] LSL output failed: $e');
    }
  }

  Future<void> _say(String text) =>
      _voice.speak(text).catchError((Object e) => debugPrint('[focus] speech failed: $e'));

  void _setState(FocusState state, String status) {
    _state = state;
    statusText = status;
    notifyListeners();
  }

  void _setStatus(String status) {
    statusText = status;
    notifyListeners();
  }

  static String _date(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// Calibration blocks and the windows that fall in their usable part.
class _Calibration {
  _Calibration(this.settings);

  final FocusCalibrationSettings settings;
  final blocks = <_Block>[];

  void startBlock({required bool focus, required double cue}) {
    blocks.lastOrNull?.end = cue;
    blocks.add(_Block(focus: focus, cue: cue));
  }

  void endLastBlock(double t) => blocks.lastOrNull?.end ??= t;

  void add(FocusWindow w) {
    final block = blocks.lastWhere((b) => b.cue <= w.start, orElse: () => _Block.none);
    if (identical(block, _Block.none)) return;
    final end = block.end;
    if (w.start < block.cue + settings.settleSeconds || (end != null && w.end > end)) return;
    if (w.lostFraction > FocusSession.maxLostFraction) return;
    block.windows.add(w);
  }
}

class _Block {
  _Block({required this.focus, required this.cue});

  static final none = _Block(focus: false, cue: 0);

  final bool focus;
  final double cue;
  double? end;
  final windows = <FocusWindow>[];
}

class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
}
