import 'dart:math' as math;
import 'dart:typed_data';

import 'biquad.dart';
import 'protocol.dart';
import 'stream_processor.dart';

/// One tone of an oddball run.
class StimulusEvent {
  const StimulusEvent({required this.onset, required this.rare});

  /// When the tone was heard, in LSL clock seconds (output latency included).
  final double onset;
  final bool rare;
}

/// Ch1–Ch12 around one tone, in µV: band-passed, resampled to [rate] Hz from
/// [start] to [end] seconds after onset, and baseline-corrected to the mean
/// before onset.
class ErpEpoch {
  ErpEpoch(this.event, this.channels, {required this.lostFraction});

  static const start = -0.2;
  static const end = 0.8;
  static const rate = 250;

  /// Samples per epoch: (end - start) * rate + 1.
  static const length = 251;

  /// Samples before onset, the baseline.
  static const baselineLength = 50;

  static double timeAt(int i) => start + i / rate;

  final StimulusEvent event;
  final List<Float64List> channels;

  /// Fraction of samples in the epoch lost over Bluetooth and interpolated.
  final double lostFraction;
}

enum EpochRejection {
  noData('EEG did not cover the tone'),
  dropout('Bluetooth dropout'),
  lostData('too much data lost in transit');

  const EpochRejection(this.label);

  final String label;
}

class EpochOutcome {
  const EpochOutcome(this.event, {this.epoch, this.rejection});

  final StimulusEvent event;
  final ErpEpoch? epoch;
  final EpochRejection? rejection;
}

/// Cuts epochs around tones out of the live EEG.
///
/// Each epoch is taken with [padding] extra seconds either side, put on an even
/// 500 Hz grid by its timestamps (the headset runs at ~496.5 Hz, and with
/// interpolation off the samples have gaps), band-passed by [ErpFilter] and
/// then trimmed, so filter edge effects fall outside the epoch. An epoch is
/// therefore ready [ErpEpoch.end] + [padding] seconds after its tone.
class EpochExtractor {
  EpochExtractor({
    this.channelCount = Mw75Protocol.eegChannelCount,
    this.maxLostFraction = 0.5,
    this.highPass = 0.5,
  });

  static const padding = 1.0;
  static const _gridRate = 500;
  static const _keepSeconds = 10.0;

  /// Longer than this between consecutive samples and the epoch is not used.
  static const _maxGap = 0.1;

  final int channelCount;

  /// Epochs with more of their samples interpolated than this are left out.
  final double maxLostFraction;

  final _times = <double>[];
  final _status = <int>[];
  late final _channels = List.generate(channelCount, (_) => <double>[]);
  final _pending = <StimulusEvent>[];
  /// High-pass cut-off, Hz. 0.5 keeps more of the slow P300; 1 is the usual
  /// choice for dry electrodes, which drift more.
  final double highPass;
  late final _filter = ErpFilter(highPass: highPass, rate: _gridRate.toDouble());

  void addEvent(StimulusEvent event) => _pending.add(event);

  /// Adds samples and returns the tones whose epochs are now complete.
  List<EpochOutcome> addSamples(List<Mw75Sample> samples) {
    for (final s in samples) {
      _times.add(s.time);
      _status.add(s.status);
      for (var c = 0; c < channelCount; c++) {
        // Unfiltered: the stream's causal filters would shift latencies.
        _channels[c].add(s.raw[c]);
      }
    }
    final outcomes = <EpochOutcome>[];
    if (_times.isNotEmpty) {
      final latest = _times.last;
      _pending.removeWhere((e) {
        if (latest < e.onset + ErpEpoch.end + padding) return false;
        outcomes.add(_extract(e));
        return true;
      });
    }
    _trim();
    return outcomes;
  }

  /// Forgets tones still waiting for EEG.
  void clearPending() => _pending.clear();

  void clear() {
    _pending.clear();
    _times.clear();
    _status.clear();
    for (final c in _channels) {
      c.clear();
    }
  }

  EpochOutcome _extract(StimulusEvent e) {
    final from = e.onset + ErpEpoch.start - padding;
    final to = e.onset + ErpEpoch.end + padding;
    if (_times.isEmpty || _times.first > from) return EpochOutcome(e, rejection: EpochRejection.noData);
    final i0 = math.max(0, _firstAtOrAfter(from) - 1);
    final i1 = math.min(_times.length - 1, _firstAtOrAfter(to));

    var lost = 0, inEpoch = 0;
    for (var i = i0; i <= i1; i++) {
      if (_status[i] == SampleStatus.afterLongDropout || (i > i0 && _times[i] - _times[i - 1] > _maxGap)) {
        return EpochOutcome(e, rejection: EpochRejection.dropout);
      }
      final t = _times[i] - e.onset;
      if (t >= ErpEpoch.start && t <= ErpEpoch.end) {
        inEpoch++;
        if (_status[i] == SampleStatus.interpolated) lost++;
      }
    }
    final lostFraction = inEpoch == 0 ? 1.0 : lost / inEpoch;
    if (lostFraction > maxLostFraction) return EpochOutcome(e, rejection: EpochRejection.lostData);

    // Where each grid point falls between two samples; shared by all channels.
    final n = ((to - from) * _gridRate).round() + 1;
    final index = Int32List(n);
    final weight = Float64List(n);
    var j = i0;
    for (var k = 0; k < n; k++) {
      final t = from + k / _gridRate;
      while (j + 1 < i1 && _times[j + 1] <= t) {
        j++;
      }
      final span = _times[j + 1] - _times[j];
      index[k] = j;
      weight[k] = span <= 0 ? 0 : ((t - _times[j]) / span).clamp(0.0, 1.0);
    }

    final skip = (padding * _gridRate).round();
    final step = _gridRate ~/ ErpEpoch.rate;
    final channels = <Float64List>[];
    for (final data in _channels) {
      final x = Float64List(n);
      var mean = 0.0;
      for (var k = 0; k < n; k++) {
        final i = index[k];
        x[k] = data[i] + (data[i + 1] - data[i]) * weight[k];
        mean += x[k];
      }
      mean /= n;
      for (var k = 0; k < n; k++) {
        x[k] -= mean;
      }
      _filter.apply(x);
      final epoch = Float64List(ErpEpoch.length);
      var baseline = 0.0;
      for (var i = 0; i < ErpEpoch.length; i++) {
        epoch[i] = x[skip + i * step];
        if (i < ErpEpoch.baselineLength) baseline += epoch[i];
      }
      baseline /= ErpEpoch.baselineLength;
      for (var i = 0; i < ErpEpoch.length; i++) {
        epoch[i] -= baseline;
      }
      channels.add(epoch);
    }
    return EpochOutcome(e, epoch: ErpEpoch(e, channels, lostFraction: lostFraction));
  }

  void _trim() {
    if (_times.isEmpty) return;
    final cut = _firstAtOrAfter(_times.last - _keepSeconds);
    // Trim in chunks so most batches do not shift the whole buffer.
    if (cut < _gridRate) return;
    _times.removeRange(0, cut);
    _status.removeRange(0, cut);
    for (final c in _channels) {
      c.removeRange(0, cut);
    }
  }

  int _firstAtOrAfter(double t) {
    var lo = 0, hi = _times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// Zero-phase band-pass for epochs: a 2nd-order Butterworth high-pass and a
/// 4th-order Butterworth low-pass, run forwards and then backwards so that
/// components keep their latency. Running twice squares the response, so the
/// cut-offs are the −6 dB points.
class ErpFilter {
  ErpFilter({this.highPass = 0.5, this.lowPass = 20, this.rate = 500})
    : _stages = [
        Biquad.highPass(highPass, rate, Biquad.butterworthQs(2).single),
        for (final q in Biquad.butterworthQs(4)) Biquad.lowPass(lowPass, rate, q),
      ];

  final double highPass;
  final double lowPass;
  final double rate;
  final List<Biquad> _stages;

  /// Filters [x] in place.
  void apply(Float64List x) {
    for (final s in _stages) {
      s.run(x);
    }
    for (final s in _stages) {
      s.run(x, forward: false);
    }
  }
}

/// A permutation test of the mean amplitude in a time window.
class WindowTest {
  const WindowTest({
    required this.from,
    required this.to,
    required this.effect,
    required this.p,
    required this.trials,
    required this.permutations,
  });

  /// Window, in seconds after onset.
  final double from;
  final double to;

  /// Mean amplitude (µV): of all tones, or rare minus standard.
  final double effect;

  /// Two-sided p-value. Never below 1 / (permutations + 1).
  final double p;
  final int trials;
  final int permutations;

  bool get atFloor => p <= 1 / (permutations + 1) + 1e-12;
}

/// Averages and tests for one set of channels.
class ErpSummary {
  ErpSummary._({
    required this.standardMean,
    required this.standardSe,
    required this.rareMean,
    required this.rareSe,
    required this.standardCount,
    required this.rareCount,
    required this.artifactCount,
    this.response,
    this.oddball,
  });

  /// Auditory N1, the brain's first large response to any sound.
  static const responseWindow = (0.08, 0.15);

  /// P300, larger for the rare tone when it is noticed. Around the ear it
  /// peaks later than on the scalp (≈400 ms in Debener et al. 2015, ≈500 ms
  /// in Eidel et al. 2024, both cEEGrid), hence a window reaching 600 ms.
  static const oddballWindow = (0.3, 0.6);

  /// Fewest epochs before a test is run.
  static const minTrials = 10;
  static const minRare = 5;

  /// Averages [epochs] over [channels], or, with [minus], the mean of
  /// [channels] minus the mean of [minus] (a bipolar derivation such as an
  /// ear cup's top electrode minus its bottom one). Epochs whose trace spans
  /// more than [rejectAbove] µV (eye movements, jaw clenches) are left out.
  ///
  /// With [tests], also runs two permutation tests: whether the mean in
  /// [responseWindow] over all tones differs from zero (sign flips), and
  /// whether rare and standard tones differ in [oddballWindow] (label
  /// shuffles). The seed is fixed so the same data gives the same p-value.
  factory ErpSummary.compute(
    List<ErpEpoch> epochs,
    List<int> channels, {
    List<int> minus = const [],
    double? rejectAbove,
    bool tests = true,
    int permutations = 2000,
  }) {
    final standard = <Float64List>[];
    final rare = <Float64List>[];
    var artifacts = 0;
    for (final e in epochs) {
      final trace = _derive(e, channels, minus);
      if (rejectAbove != null && _peakToPeak(trace) > rejectAbove) {
        artifacts++;
        continue;
      }
      (e.event.rare ? rare : standard).add(trace);
    }
    final (standardMean, standardSe) = _meanAndSe(standard);
    final (rareMean, rareSe) = _meanAndSe(rare);

    WindowTest? response, oddball;
    if (tests) {
      final random = math.Random(1);
      final all = [...standard, ...rare];
      if (all.length >= minTrials) {
        response = _signFlipTest([for (final t in all) _windowMean(t, responseWindow)], responseWindow, permutations, random);
      }
      if (rare.length >= minRare && standard.length >= minRare) {
        oddball = _labelShuffleTest(
          [for (final t in rare) _windowMean(t, oddballWindow)],
          [for (final t in standard) _windowMean(t, oddballWindow)],
          oddballWindow,
          permutations,
          random,
        );
      }
    }
    return ErpSummary._(
      standardMean: standardMean,
      standardSe: standardSe,
      rareMean: rareMean,
      rareSe: rareSe,
      standardCount: standard.length,
      rareCount: rare.length,
      artifactCount: artifacts,
      response: response,
      oddball: oddball,
    );
  }

  final Float64List standardMean;
  final Float64List standardSe;
  final Float64List rareMean;
  final Float64List rareSe;
  final int standardCount;
  final int rareCount;

  /// Epochs left out by the amplitude threshold.
  final int artifactCount;
  final WindowTest? response;
  final WindowTest? oddball;

  bool get isEmpty => standardCount + rareCount == 0;

  /// Rare minus standard, once both have epochs.
  Float64List? get difference {
    if (standardCount == 0 || rareCount == 0) return null;
    return Float64List.fromList([for (var i = 0; i < ErpEpoch.length; i++) rareMean[i] - standardMean[i]]);
  }

  /// Largest |mean ± SE| of either trace or the difference, for scaling plots.
  double get peak {
    var peak = 0.0;
    void scan(Float64List mean, Float64List se, int count) {
      if (count == 0) return;
      for (var i = 0; i < mean.length; i++) {
        peak = math.max(peak, mean[i].abs() + se[i]);
      }
    }

    scan(standardMean, standardSe, standardCount);
    scan(rareMean, rareSe, rareCount);
    final d = difference;
    if (d != null) {
      for (final v in d) {
        peak = math.max(peak, v.abs());
      }
    }
    return peak;
  }

  /// Mean of [trace] over [window], in µV.
  static double windowMean(Float64List trace, (double, double) window) => _windowMean(trace, window);

  static Float64List _derive(ErpEpoch e, List<int> channels, List<int> minus) {
    final plus = _average(e, channels);
    if (minus.isEmpty) return plus;
    final less = _average(e, minus);
    return Float64List.fromList([for (var i = 0; i < plus.length; i++) plus[i] - less[i]]);
  }

  static Float64List _average(ErpEpoch e, List<int> channels) {
    if (channels.length == 1) return e.channels[channels.first];
    final out = Float64List(ErpEpoch.length);
    for (final c in channels) {
      final data = e.channels[c];
      for (var i = 0; i < out.length; i++) {
        out[i] += data[i];
      }
    }
    for (var i = 0; i < out.length; i++) {
      out[i] /= channels.length;
    }
    return out;
  }

  static double _peakToPeak(Float64List x) {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final v in x) {
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }
    return hi - lo;
  }

  static (Float64List, Float64List) _meanAndSe(List<Float64List> traces) {
    final mean = Float64List(ErpEpoch.length);
    final se = Float64List(ErpEpoch.length);
    final n = traces.length;
    if (n == 0) return (mean, se);
    for (final t in traces) {
      for (var i = 0; i < mean.length; i++) {
        mean[i] += t[i];
      }
    }
    for (var i = 0; i < mean.length; i++) {
      mean[i] /= n;
    }
    if (n < 2) return (mean, se);
    for (final t in traces) {
      for (var i = 0; i < se.length; i++) {
        final d = t[i] - mean[i];
        se[i] += d * d;
      }
    }
    for (var i = 0; i < se.length; i++) {
      se[i] = math.sqrt(se[i] / (n - 1) / n);
    }
    return (mean, se);
  }

  static double _windowMean(Float64List trace, (double, double) window) {
    final from = ((window.$1 - ErpEpoch.start) * ErpEpoch.rate).round();
    final to = ((window.$2 - ErpEpoch.start) * ErpEpoch.rate).round();
    var sum = 0.0;
    for (var i = from; i <= to; i++) {
      sum += trace[i];
    }
    return sum / (to - from + 1);
  }

  static WindowTest _signFlipTest(List<double> values, (double, double) window, int permutations, math.Random random) {
    final n = values.length;
    final observed = values.fold(0.0, (a, b) => a + b) / n;
    var hits = 0;
    for (var p = 0; p < permutations; p++) {
      var sum = 0.0;
      for (final v in values) {
        sum += random.nextBool() ? v : -v;
      }
      if ((sum / n).abs() >= observed.abs() - 1e-12) hits++;
    }
    return WindowTest(
      from: window.$1,
      to: window.$2,
      effect: observed,
      p: (hits + 1) / (permutations + 1),
      trials: n,
      permutations: permutations,
    );
  }

  static WindowTest _labelShuffleTest(
    List<double> rare,
    List<double> standard,
    (double, double) window,
    int permutations,
    math.Random random,
  ) {
    final pool = Float64List.fromList([...rare, ...standard]);
    final n = pool.length;
    final k = rare.length;
    final total = pool.fold(0.0, (a, b) => a + b);
    double diff(double rareSum) => rareSum / k - (total - rareSum) / (n - k);
    final observed = diff(rare.fold(0.0, (a, b) => a + b));
    var hits = 0;
    for (var p = 0; p < permutations; p++) {
      // A partial Fisher–Yates shuffle draws a random set of k as "rare".
      var sum = 0.0;
      for (var i = 0; i < k; i++) {
        final j = i + random.nextInt(n - i);
        final t = pool[i];
        pool[i] = pool[j];
        pool[j] = t;
        sum += pool[i];
      }
      if (diff(sum).abs() >= observed.abs() - 1e-12) hits++;
    }
    return WindowTest(
      from: window.$1,
      to: window.$2,
      effect: observed,
      p: (hits + 1) / (permutations + 1),
      trials: n,
      permutations: permutations,
    );
  }
}
