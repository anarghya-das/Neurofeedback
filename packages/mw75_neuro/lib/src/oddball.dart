import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'erp.dart';
import 'headset.dart';
import 'lsl_eeg_outlet.dart';
import 'stream_processor.dart';
import 'test_runs.dart';
import 'tone_output.dart';

/// Parameters of an auditory oddball run. The defaults are the classic
/// paradigm: 100 ms tones, 1000 Hz and 2000 Hz, one in five rare, about one
/// tone a second.
@immutable
class OddballSettings {
  const OddballSettings({
    this.trials = 200,
    this.rareProbability = 0.2,
    this.rareIsHigh = true,
    this.lowHz = 1000,
    this.highHz = 2000,
    this.toneSeconds = 0.1,
    this.amplitude = 0.3,
    this.minInterval = 1.0,
    this.maxInterval = 1.3,
  });

  final int trials;
  final double rareProbability;

  /// Which tone is rare. Running once each way and pooling the results means
  /// a rare-vs-standard difference cannot come from the pitch itself.
  final bool rareIsHigh;
  final double lowHz;
  final double highHz;
  final double toneSeconds;

  /// Peak level, 0–1 of full scale; the system volume applies on top.
  final double amplitude;

  /// Onset-to-onset interval in seconds, drawn uniformly from this range so
  /// tones cannot be anticipated. At least the epoch length (0.8 s after onset)
  /// keeps the next tone's response out of the epoch.
  final double minInterval;
  final double maxInterval;

  double get rareHz => rareIsHigh ? highHz : lowHz;
  double get standardHz => rareIsHigh ? lowHz : highHz;

  /// Approximate length of a run.
  Duration get duration => Duration(milliseconds: (trials * (minInterval + maxInterval) / 2 * 1000).round());

  Map<String, Object?> toJson() => {
    'trials': trials,
    'rareProbability': rareProbability,
    'rareIsHigh': rareIsHigh,
    'lowHz': lowHz,
    'highHz': highHz,
    'toneSeconds': toneSeconds,
    'amplitude': amplitude,
    'minInterval': minInterval,
    'maxInterval': maxInterval,
  };

  factory OddballSettings.fromJson(Map<String, Object?> j) {
    double d(String key, double fallback) => (j[key] as num?)?.toDouble() ?? fallback;
    const defaults = OddballSettings();
    return OddballSettings(
      trials: (j['trials'] as num?)?.toInt() ?? defaults.trials,
      rareProbability: d('rareProbability', defaults.rareProbability),
      rareIsHigh: j['rareIsHigh'] as bool? ?? defaults.rareIsHigh,
      lowHz: d('lowHz', defaults.lowHz),
      highHz: d('highHz', defaults.highHz),
      toneSeconds: d('toneSeconds', defaults.toneSeconds),
      amplitude: d('amplitude', defaults.amplitude),
      minInterval: d('minInterval', defaults.minInterval),
      maxInterval: d('maxInterval', defaults.maxInterval),
    );
  }

  OddballSettings copyWith({int? trials, bool? rareIsHigh}) => OddballSettings(
    trials: trials ?? this.trials,
    rareProbability: rareProbability,
    rareIsHigh: rareIsHigh ?? this.rareIsHigh,
    lowHz: lowHz,
    highHz: highHz,
    toneSeconds: toneSeconds,
    amplitude: amplitude,
    minInterval: minInterval,
    maxInterval: maxInterval,
  );
}

/// Standard (false) and rare (true) tones in random order. The run opens with
/// [leadStandards] standards so the standard is established first, and every
/// rare tone follows at least [minStandardsBefore] standards, so rare tones
/// never come back to back.
List<bool> oddballSequence({
  required int trials,
  required double rareProbability,
  int minStandardsBefore = 2,
  int leadStandards = 3,
  math.Random? random,
}) {
  final rng = random ?? math.Random();
  final lead = math.min(leadStandards, trials);
  final room = trials - lead;
  final rares = math.min((trials * rareProbability).round(), room ~/ (minStandardsBefore + 1));
  final spare = room - rares * (minStandardsBefore + 1);
  // Spread the spare standards at random over the gaps before, between and
  // after the rare tones.
  final extra = List.filled(rares + 1, 0);
  for (var i = 0; i < spare; i++) {
    extra[rng.nextInt(rares + 1)]++;
  }
  return [
    ...List.filled(lead, false),
    for (var r = 0; r < rares; r++) ...[...List.filled(minStandardsBefore + extra[r], false), true],
    ...List.filled(extra[rares], false),
  ];
}

enum OddballState { idle, preparing, running, finishing }

/// One run's tones and epochs, live or loaded from disk.
class OddballRun {
  OddballRun({required this.started, required this.settings, this.included = true});

  static const kind = 'oddball';

  final DateTime started;
  final OddballSettings settings;
  String? output;
  double? latency;
  int trialsPlayed = 0;
  int raresPlayed = 0;
  final epochs = <ErpEpoch>[];
  final rejections = <EpochRejection, int>{};

  /// Whether this run counts towards the averages and tests.
  bool included;

  /// Where it was saved, once it has been.
  String? folder;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'version': 1,
    'started': started.toIso8601String(),
    'settings': settings.toJson(),
    'output': output,
    'latencySeconds': latency,
    'trialsPlayed': trialsPlayed,
    'raresPlayed': raresPlayed,
    'rejections': {for (final e in rejections.entries) e.key.name: e.value},
    'epochStart': ErpEpoch.start,
    'epochRate': ErpEpoch.rate,
    'epochs': [
      for (final e in epochs)
        {
          'onset': e.event.onset,
          'rare': e.event.rare,
          'lostFraction': round3(e.lostFraction),
          'uV': [
            for (final c in e.channels) [for (final v in c) round3(v)],
          ],
        },
    ],
  };

  factory OddballRun.fromJson(Map<String, Object?> j, {required String folder}) {
    final run = OddballRun(
      started: DateTime.parse(j['started'] as String),
      settings: OddballSettings.fromJson((j['settings'] as Map).cast<String, Object?>()),
      included: false,
    )
      ..folder = folder
      ..output = j['output'] as String?
      ..latency = (j['latencySeconds'] as num?)?.toDouble()
      ..trialsPlayed = (j['trialsPlayed'] as num?)?.toInt() ?? 0
      ..raresPlayed = (j['raresPlayed'] as num?)?.toInt() ?? 0;
    for (final MapEntry(:key, :value) in (j['rejections'] as Map? ?? const {}).entries) {
      final reason = EpochRejection.values.where((r) => r.name == key).firstOrNull;
      if (reason != null) run.rejections[reason] = (value as num).toInt();
    }
    for (final e in (j['epochs'] as List? ?? const []).cast<Map<Object?, Object?>>()) {
      run.epochs.add(
        ErpEpoch(
          StimulusEvent(onset: (e['onset'] as num).toDouble(), rare: e['rare'] as bool),
          [
            for (final c in (e['uV'] as List).cast<List<Object?>>())
              Float64List.fromList([for (final v in c) (v as num).toDouble()]),
          ],
          lostFraction: (e['lostFraction'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    return run;
  }
}

/// Runs an auditory oddball test against the live EEG and keeps the epochs.
///
/// Tones are scheduled ahead on the audio clock (see [ToneOutput]) and each
/// onset is matched to the EEG by LSL time. Markers go to an LSL outlet too,
/// so a LabRecorder recording can be analysed offline.
///
/// Listeners hear about state changes, not every tone or epoch: a screen
/// update locked to every tone would add a visual response to the average.
/// [progress] ticks once a second during a run, independent of tone timing;
/// rebuild counters and plots from that.
class OddballSession extends ChangeNotifier {
  OddballSession({required this.headset, ToneOutput? tones, this.store, this.publishMarkers = true})
    : _tones = tones ?? ToneOutput();

  static const markerStreamName = 'MW75 Oddball Markers';

  /// Below this recent packet loss the EEG link counts as settled.
  static const _maxLossToStart = 0.6;

  /// How long before a tone's onset it is scheduled.
  static const _scheduleAhead = 0.25;

  final Mw75Headset headset;
  final ToneOutput _tones;

  /// Where runs are saved; null keeps them in memory only.
  final TestRunStore? store;
  final bool publishMarkers;

  OddballState _state = OddballState.idle;
  OddballState get state => _state;
  bool get busy => _state != OddballState.idle;
  String statusText = 'Start raw EEG, then start the test.';

  OddballSettings _settings = const OddballSettings();
  OddballSettings get settings => _settings;
  set settings(OddballSettings value) {
    _settings = value;
    notifyListeners();
  }

  /// Epochs whose channel average spans more than this many µV are left out
  /// of averages and tests; null keeps everything.
  double? get rejectAbove => _rejectAbove;
  double? _rejectAbove = 100;
  set rejectAbove(double? value) {
    _rejectAbove = value;
    notifyListeners();
  }

  List<AudioOutputDevice> outputs = const [];

  /// Where tones play; null for the system output.
  AudioOutputDevice? get output => _output;
  AudioOutputDevice? _output;
  set output(AudioOutputDevice? value) {
    _output = value;
    notifyListeners();
  }

  /// The output in use for the current or last run.
  ToneOutputInfo? outputInfo;

  int plannedTrials = 0;
  int trialsPlayed = 0;
  int raresPlayed = 0;

  /// This session's runs and any loaded from disk, newest first.
  final runs = <OddballRun>[];

  /// The run in progress, or null.
  OddballRun? get current => _current;

  /// Kept epochs from the included runs.
  List<ErpEpoch> get epochs => [
    for (final r in runs)
      if (r.included) ...r.epochs,
  ];

  /// Why tones in the included runs gave no epoch.
  Map<EpochRejection, int> get rejections {
    final total = <EpochRejection, int>{};
    for (final r in runs.where((r) => r.included)) {
      for (final e in r.rejections.entries) {
        total.update(e.key, (n) => n + e.value, ifAbsent: () => e.value);
      }
    }
    return total;
  }

  /// Ticks once a second during a run.
  Listenable get progress => _progress;
  final _progress = _Ticker();

  final _extractor = EpochExtractor();
  final _random = math.Random();
  StreamSubscription<List<Mw75Sample>>? _samples;
  OddballRun? _current;
  RunRecorder? _recorder;
  LslMarkerOutlet? _markers;
  Timer? _progressTimer;
  int _run = 0;

  ErpSummary summary(List<int> channels, {bool tests = true}) =>
      ErpSummary.compute(epochs, channels, rejectAbove: _rejectAbove, tests: tests);

  /// Adds saved runs that are not listed yet, unticked so they only count
  /// once chosen.
  Future<void> loadSaved() async {
    final store = this.store;
    if (store == null) return;
    try {
      final known = {for (final r in runs) r.folder};
      for (final (folder, json) in await store.load(OddballRun.kind)) {
        if (known.contains(folder)) continue;
        try {
          runs.add(OddballRun.fromJson(json, folder: folder));
        } catch (e) {
          debugPrint('[oddball] could not read $folder: $e');
        }
      }
      runs.sort((a, b) => b.started.compareTo(a.started));
    } catch (e) {
      debugPrint('[oddball] could not list saved runs: $e');
    }
    notifyListeners();
  }

  void setIncluded(OddballRun run, bool included) {
    run.included = included;
    notifyListeners();
  }

  Future<void> refreshOutputs() async {
    try {
      outputs = await _tones.devices();
      if (_output != null && !outputs.any((d) => d.id == _output!.id)) _output = null;
    } catch (e) {
      statusText = 'Could not list audio outputs: ${_describe(e)}';
    }
    notifyListeners();
  }

  /// Plays the standard tone, then the rare one.
  Future<void> preview() async {
    if (busy) return;
    final run = ++_run;
    _setState(OddballState.preparing, 'Playing the standard tone, then the rare one…');
    try {
      outputInfo = await _tones.start(deviceId: _output?.id);
      final first = await _play(rare: false, at: null);
      await _play(rare: true, at: first + 0.8);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
    } catch (e) {
      if (run == _run) statusText = 'Could not play tones: ${_describe(e)}';
    }
    if (run != _run) return;
    await _tones.stop().catchError((_) {});
    _setState(OddballState.idle, 'Standard ${_hz(_settings.standardHz)}, then rare ${_hz(_settings.rareHz)}.');
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
    _setState(OddballState.preparing, 'Starting audio…');
    try {
      outputInfo = await _tones.start(deviceId: _output?.id);
    } catch (e) {
      if (run == _run) _setState(OddballState.idle, 'Could not start audio: ${_describe(e)}');
      return;
    }
    if (run != _run) {
      // Stopped while the audio was starting.
      await _tones.stop().catchError((_) {});
      return;
    }
    final current = OddballRun(started: DateTime.now(), settings: settings)
      ..output = outputInfo?.device
      ..latency = outputInfo?.latency;
    _current = current;
    runs.insert(0, current);
    try {
      _recorder = await store?.begin(OddballRun.kind, current.started);
    } catch (e) {
      debugPrint('[oddball] not saving this run: $e');
    }
    if (run != _run) {
      // Stopped while the run folder was being made.
      runs.remove(current);
      await _recorder?.discard();
      _recorder = null;
      _current = null;
      return;
    }
    _openMarkers();
    _extractor.clear();
    _samples = headset.samples.listen(_onSamples);
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) => _progress.tick());

    // Let a Bluetooth output wake up and the EEG buffer fill before the first
    // tone, then wait (a while) for the EEG link to settle.
    _setStatus('Getting ready…');
    await Future<void>.delayed(const Duration(seconds: 2));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (run == _run && (headset.recentLossRatio ?? 1) > _maxLossToStart && DateTime.now().isBefore(deadline)) {
      final loss = headset.recentLossRatio;
      _setStatus('Waiting for the EEG link to settle${loss == null ? '' : ' (${(loss * 100).round()}% loss)'}…');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (run != _run) return;

    final sequence = oddballSequence(
      trials: settings.trials,
      rareProbability: settings.rareProbability,
      random: _random,
    );
    plannedTrials = sequence.length;
    trialsPlayed = 0;
    raresPlayed = 0;
    _setState(
      OddballState.running,
      'Silently count the ${settings.rareIsHigh ? 'high' : 'low'} tones. Keep still and look at one spot.',
    );
    _marker(
      'run_start standard=${_hz(settings.standardHz)} rare=${_hz(settings.rareHz)}',
      LslEegOutlet.localClock(),
    );

    double? next;
    for (final rare in sequence) {
      if (headset.state != HeadsetState.streaming) {
        await _end(run, 'Raw EEG stopped, so the test stopped after $trialsPlayed tones.');
        return;
      }
      if (next != null) {
        final wait = next - LslEegOutlet.localClock() - _scheduleAhead;
        if (wait > 0) await Future<void>.delayed(Duration(microseconds: (wait * 1e6).round()));
        if (run != _run) return;
      }
      final double onset;
      try {
        onset = await _play(rare: rare, at: next, settings: settings);
      } catch (e) {
        await _end(run, 'Audio stopped after $trialsPlayed tones: ${_describe(e)}');
        return;
      }
      if (run != _run) return;
      _extractor.addEvent(StimulusEvent(onset: onset, rare: rare));
      _marker(
        rare ? 'rare ${_hz(settings.rareHz)}' : 'standard ${_hz(settings.standardHz)}',
        onset,
      );
      trialsPlayed++;
      current.trialsPlayed++;
      if (rare) {
        raresPlayed++;
        current.raresPlayed++;
      }
      next = onset + settings.minInterval + _random.nextDouble() * (settings.maxInterval - settings.minInterval);
    }

    _setState(OddballState.finishing, 'Collecting the last responses…');
    await Future<void>.delayed(
      Duration(milliseconds: ((ErpEpoch.end + EpochExtractor.padding + 1) * 1000).round()),
    );
    await _end(run, 'Done: $trialsPlayed tones, $raresPlayed of them rare. Did you count $raresPlayed?');
  }

  Future<void> stop() async {
    if (!busy) return;
    await _end(_run, 'Stopped after $trialsPlayed tones.');
  }

  /// Takes every run out of the averages. Saved runs stay on disk.
  void clearResults() {
    for (final r in runs) {
      r.included = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _run++;
    _progressTimer?.cancel();
    _samples?.cancel();
    unawaited(_recorder?.discard());
    unawaited(_tones.stop().catchError((_) {}));
    _markers?.close();
    _progress.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  Future<double> _play({required bool rare, required double? at, OddballSettings? settings}) {
    final s = settings ?? _settings;
    return _tones.play(
      frequency: rare ? s.rareHz : s.standardHz,
      duration: s.toneSeconds,
      amplitude: s.amplitude,
      at: at,
    );
  }

  /// Ends run [run] if it is still the current one.
  Future<void> _end(int run, String message) async {
    if (run != _run) return;
    _run++;
    if (_state == OddballState.running || _state == OddballState.finishing) {
      _marker('run_end', LslEegOutlet.localClock());
    }
    _progressTimer?.cancel();
    _progressTimer = null;
    await _samples?.cancel();
    _samples = null;
    _extractor.clearPending();
    await _tones.stop().catchError((_) {});
    await _save(message);
  }

  Future<void> _save(String message) async {
    final current = _current;
    final recorder = _recorder;
    _current = null;
    _recorder = null;
    var status = message;
    if (current != null && recorder != null) {
      try {
        if (current.trialsPlayed == 0) {
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
    _setState(OddballState.idle, status);
  }

  void _onSamples(List<Mw75Sample> samples) {
    _recorder?.addSamples(samples);
    final current = _current;
    if (current == null) return;
    for (final outcome in _extractor.addSamples(samples)) {
      final epoch = outcome.epoch;
      if (epoch != null) {
        current.epochs.add(epoch);
      } else {
        current.rejections.update(outcome.rejection!, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  void _openMarkers() {
    if (!publishMarkers || _markers != null) return;
    try {
      _markers = LslMarkerOutlet.create(
        name: markerStreamName,
        sourceId: 'mw75-oddball-markers',
        extraDesc: const {
          'markers': '"standard <Hz>" and "rare <Hz>" at each tone onset as heard (output latency included); '
              '"run_start ..." and "run_end" around each run',
        },
      );
    } catch (e) {
      debugPrint('[oddball] marker outlet failed: $e');
    }
  }

  void _marker(String text, double time) => _markers?.push(text, time);

  void _setState(OddballState state, String status) {
    _state = state;
    statusText = status;
    notifyListeners();
  }

  void _setStatus(String status) {
    statusText = status;
    notifyListeners();
  }

  static String _hz(double hz) => '${hz.round()} Hz';

  static String _describe(Object e) => e is PlatformException ? e.message ?? e.code : e.toString();
}

class _Ticker extends ChangeNotifier {
  void tick() => notifyListeners();
}
