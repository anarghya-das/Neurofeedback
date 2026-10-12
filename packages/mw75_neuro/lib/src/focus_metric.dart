import 'dart:math' as math;
import 'dart:typed_data';

import 'band_power.dart';
import 'protocol.dart';
import 'stream_processor.dart';

/// A frequency band used as a focus feature.
class FocusBand {
  const FocusBand(this.name, this.low, this.high);

  final String name;
  final double low;
  final double high;
}

/// Spectral features of the last ~2 s of EEG, every ~0.5 s, for the focus
/// model.
///
/// Features are each band's share of 2–30 Hz power, log10, per channel, for
/// [bands]: theta, alpha and low beta. Ear-EEG studies find attention and
/// workload in these bands (Getzmann et al. 2021, who used these relative
/// "fractions"; Crétot-Richert et al. 2023; Neurable's Enten whitepaper,
/// 2021). Shares rather than absolute power, because movement and changes in
/// electrode contact shift all frequencies together: the first calibration
/// on the lab headset was swamped by such broadband jumps. Stopping at 20 Hz
/// keeps jaw and temple muscle activity, which dominates higher frequencies
/// at the ears, out of the features. Muscle (30–45 Hz) and broadband
/// (2–30 Hz) power are measured separately, only to flag noisy windows.
/// Windows use the unfiltered samples.
class FocusFeatureExtractor {
  FocusFeatureExtractor({this.channelCount = Mw75Protocol.eegChannelCount});

  /// Samples per window (~2.06 s at 496.5 Hz): three half-overlapping
  /// 512-sample segments, averaged (Welch).
  static const windowSamples = 1024;
  static const hop = 256;
  static const bands = [FocusBand('theta', 4, 8), FocusBand('alpha', 8, 13), FocusBand('low beta', 13, 20)];
  static const muscleBand = FocusBand('muscle', 30, 45);
  static const totalBand = FocusBand('total', 2, 30);
  static const _maxGap = 0.1;

  final int channelCount;
  int get featureCount => channelCount * bands.length;

  final _times = <double>[];
  final _status = <int>[];
  late final _channels = List.generate(channelCount, (_) => <double>[]);
  final _spectrum = SegmentSpectrum();
  int _sinceLast = 0;

  /// Feature [i] is band `i % bands.length` of channel `i ~/ bands.length`.
  static String featureName(int i) => 'Ch${i ~/ bands.length + 1} ${bands[i % bands.length].name}';

  List<FocusWindow> add(List<Mw75Sample> samples, {required double sampleRate}) {
    final out = <FocusWindow>[];
    for (final s in samples) {
      _times.add(s.time);
      _status.add(s.status);
      for (var c = 0; c < channelCount; c++) {
        _channels[c].add(s.raw[c]);
      }
      if (++_sinceLast >= hop && _times.length >= windowSamples) {
        _sinceLast = 0;
        final w = _analyse(sampleRate);
        if (w != null) out.add(w);
      }
    }
    final excess = _times.length - windowSamples;
    if (excess > 4 * windowSamples) {
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

  /// Null when the window spans a Bluetooth dropout or a gap in time: its
  /// spectrum would be meaningless.
  FocusWindow? _analyse(double sampleRate) {
    final start = _times.length - windowSamples;
    var lost = 0;
    for (var i = start; i < _times.length; i++) {
      if (_status[i] == SampleStatus.afterLongDropout) return null;
      if (i > start && _times[i] - _times[i - 1] > _maxGap) return null;
      if (_status[i] == SampleStatus.interpolated) lost++;
    }
    final binHz = sampleRate / SegmentSpectrum.size;
    final features = Float64List(featureCount);
    var muscle = 0.0, broadband = 0.0;
    for (var c = 0; c < channelCount; c++) {
      final psd = Float64List(SegmentSpectrum.bins);
      for (final offset in const [0, SegmentSpectrum.size ~/ 2, SegmentSpectrum.size]) {
        final segment = _spectrum.psd(_channels[c], start + offset, sampleRate);
        for (var k = 0; k < psd.length; k++) {
          psd[k] += segment[k] / 3;
        }
      }
      final total = math.max(bandPowerOf(psd, binHz, totalBand.low, totalBand.high), 1e-9);
      for (var b = 0; b < bands.length; b++) {
        final power = bandPowerOf(psd, binHz, bands[b].low, bands[b].high);
        features[c * bands.length + b] = math.log(math.max(power / total, 1e-9)) / math.ln10;
      }
      muscle += bandPowerOf(psd, binHz, muscleBand.low, muscleBand.high) / channelCount;
      broadband += total / channelCount;
    }
    return FocusWindow(
      start: _times[start],
      end: _times.last,
      features: features,
      muscle: math.log(math.max(muscle, 1e-6)) / math.ln10,
      broadband: math.log(math.max(broadband, 1e-6)) / math.ln10,
      lostFraction: lost / windowSamples,
    );
  }

  /// Power in [low, high) Hz of a density spectrum with bins [binHz] apart.
  static double bandPowerOf(List<double> psd, double binHz, double low, double high) {
    var sum = 0.0;
    for (var k = 0; k < psd.length; k++) {
      final f = k * binHz;
      if (f >= low && f < high) sum += psd[k] * binHz;
    }
    return sum;
  }
}

/// One analysed window.
class FocusWindow {
  const FocusWindow({
    required this.start,
    required this.end,
    required this.features,
    required this.muscle,
    required this.broadband,
    required this.lostFraction,
  });

  /// LSL times of the first and last sample.
  final double start;
  final double end;
  final Float64List features;

  /// log10 of 30–45 Hz power, averaged over channels: muscle activity.
  final double muscle;

  /// log10 of 2–30 Hz power, averaged over channels: jumps with movement and
  /// contact changes.
  final double broadband;

  /// Share of samples lost over Bluetooth and interpolated.
  final double lostFraction;
}

/// A personal focus model: robust scaling, then a shrinkage linear
/// discriminant between the user's own "focused" and "resting" calibration
/// windows. The score is the model's probability of "focused", as in
/// Neurable's approach (an SVM's probability of the easy task, on robustly
/// scaled band powers); per-person linear discriminants on ear-EEG spectra
/// reached 85–95% in Crétot-Richert et al. (2023).
class FocusModel {
  FocusModel({
    required this.center,
    required this.scale,
    required this.weights,
    required this.bias,
    required this.muscleLimit,
    required this.broadbandLimit,
    required this.cvAccuracy,
    required this.cvAuc,
    required this.trainedOn,
    required this.blocksUsed,
    required this.blocksLeftOut,
    required this.windowsLeftOut,
    required this.created,
  });

  static const version = 2;

  /// Blocks with fewer clean windows than this (of ~50) are left out.
  static const minBlockWindows = 12;

  /// Robust scaling, per feature: (x - median) / interquartile range, over
  /// all calibration windows. Unlike a z-score, a few artifact windows do not
  /// distort it, and it puts sessions with different contact on one scale.
  final Float64List center;
  final Float64List scale;

  /// Log-odds of "focused" = weights · scaled + bias.
  final Float64List weights;
  final double bias;

  /// Windows with more muscle or broadband power than these (log10 µV²) are
  /// too noisy to score or train on: the calibration median plus three
  /// interquartile ranges.
  final double muscleLimit;
  final double broadbandLimit;

  /// Block-wise cross-validated accuracy and area under the ROC curve: how
  /// well the model told focus from rest in blocks it had not seen.
  final double cvAccuracy;
  final double cvAuc;

  /// Calibration windows and blocks used: (focused, resting).
  final (int, int) trainedOn;
  final (int, int) blocksUsed;

  /// Left out: blocks with too few clean windows, and artifact windows.
  final int blocksLeftOut;
  final int windowsLeftOut;
  final DateTime created;

  bool isClean(FocusWindow w) => w.muscle <= muscleLimit && w.broadband <= broadbandLimit;

  /// Probability (0–1) that [features] come from the focused state.
  double probability(Float64List features) {
    var z = bias;
    for (var i = 0; i < weights.length; i++) {
      z += weights[i] * (features[i] - center[i]) / scale[i];
    }
    return 1 / (1 + math.exp(-z));
  }

  /// What drives the score: summed weight per band and ear cup, largest
  /// first. A positive weight means a larger share of power in that band
  /// when focused.
  List<(String, double)> drivers() {
    final groups = <String, double>{};
    for (var i = 0; i < weights.length; i++) {
      final channel = i ~/ FocusFeatureExtractor.bands.length;
      final band = FocusFeatureExtractor.bands[i % FocusFeatureExtractor.bands.length].name;
      final key = '$band, ${channel < 6 ? 'left' : 'right'} cup';
      groups.update(key, (v) => v + weights[i], ifAbsent: () => weights[i]);
    }
    return groups.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
  }

  Map<String, Object?> toJson() => {
    'kind': 'focus-model',
    'version': version,
    'features': 'log10 share of 2-30 Hz power per channel and band',
    'created': created.toIso8601String(),
    'bands': [
      for (final b in FocusFeatureExtractor.bands) [b.name, b.low, b.high],
    ],
    'center': center,
    'scale': scale,
    'weights': weights,
    'bias': bias,
    'muscleLimit': muscleLimit,
    'broadbandLimit': broadbandLimit,
    'cvAccuracy': cvAccuracy,
    'cvAuc': cvAuc,
    'trainedOn': [trainedOn.$1, trainedOn.$2],
    'blocksUsed': [blocksUsed.$1, blocksUsed.$2],
    'blocksLeftOut': blocksLeftOut,
    'windowsLeftOut': windowsLeftOut,
  };

  /// Throws [FormatException] for models from an earlier version, whose
  /// features differ.
  factory FocusModel.fromJson(Map<String, Object?> j) {
    if (j['version'] != version) throw const FormatException('Calibration from an earlier version');
    Float64List list(String key) => Float64List.fromList([for (final v in j[key] as List) (v as num).toDouble()]);
    final trained = (j['trainedOn'] as List).cast<num>();
    final blocks = (j['blocksUsed'] as List).cast<num>();
    return FocusModel(
      center: list('center'),
      scale: list('scale'),
      weights: list('weights'),
      bias: (j['bias'] as num).toDouble(),
      muscleLimit: (j['muscleLimit'] as num).toDouble(),
      broadbandLimit: (j['broadbandLimit'] as num).toDouble(),
      cvAccuracy: (j['cvAccuracy'] as num).toDouble(),
      cvAuc: (j['cvAuc'] as num).toDouble(),
      trainedOn: (trained[0].toInt(), trained[1].toInt()),
      blocksUsed: (blocks[0].toInt(), blocks[1].toInt()),
      blocksLeftOut: (j['blocksLeftOut'] as num).toInt(),
      windowsLeftOut: (j['windowsLeftOut'] as num).toInt(),
      created: DateTime.parse(j['created'] as String),
    );
  }

  /// Trains on calibration windows grouped by block.
  ///
  /// First, artifact windows (muscle or broadband power past the limits) are
  /// dropped, then blocks left with fewer than [minBlockWindows] windows.
  /// Each fold of the cross-validation holds out one focus block and one rest
  /// block, so the score reflects new stretches of time, not neighbouring
  /// windows of the same block (which are nearly identical and would inflate
  /// accuracy). Throws [StateError] with fewer than two usable blocks of each.
  static FocusModel train({
    required List<List<FocusWindow>> focusBlocks,
    required List<List<FocusWindow>> restBlocks,
    DateTime? now,
  }) {
    final everything = [
      for (final b in [...focusBlocks, ...restBlocks]) ...b,
    ];
    if (everything.isEmpty) throw StateError('No calibration windows');
    final muscleLimit = _limit([for (final w in everything) w.muscle]);
    final broadbandLimit = _limit([for (final w in everything) w.broadband]);
    bool clean(FocusWindow w) => w.muscle <= muscleLimit && w.broadband <= broadbandLimit;
    var windowsLeftOut = 0, blocksLeftOut = 0;
    List<List<FocusWindow>> keep(List<List<FocusWindow>> blocks) {
      final kept = <List<FocusWindow>>[];
      for (final b in blocks) {
        final good = b.where(clean).toList();
        windowsLeftOut += b.length - good.length;
        if (good.length >= minBlockWindows) {
          kept.add(good);
        } else {
          blocksLeftOut++;
          windowsLeftOut += good.length;
        }
      }
      return kept;
    }

    focusBlocks = keep(focusBlocks);
    restBlocks = keep(restBlocks);
    if (focusBlocks.length < 2 || restBlocks.length < 2) {
      throw StateError(
        'Only ${focusBlocks.length} focus and ${restBlocks.length} rest blocks had enough clean EEG; '
        'at least 2 of each are needed.',
      );
    }
    final focus = [for (final b in focusBlocks) ...b];
    final rest = [for (final b in restBlocks) ...b];

    final folds = math.min(focusBlocks.length, restBlocks.length);
    final scores = <(double, bool)>[];
    for (var k = 0; k < folds; k++) {
      final model = _fit(
        [
          for (var i = 0; i < focusBlocks.length; i++)
            if (i != k) ...focusBlocks[i],
        ],
        [
          for (var i = 0; i < restBlocks.length; i++)
            if (i != k) ...restBlocks[i],
        ],
      );
      if (model == null) continue;
      for (final w in focusBlocks[k]) {
        scores.add((model.probability(w.features), true));
      }
      for (final w in restBlocks[k]) {
        scores.add((model.probability(w.features), false));
      }
    }
    final full = _fit(focus, rest)!;
    final correct = scores.where((s) => (s.$1 >= 0.5) == s.$2).length;
    return FocusModel(
      center: full.center,
      scale: full.scale,
      weights: full.weights,
      bias: full.bias,
      muscleLimit: muscleLimit,
      broadbandLimit: broadbandLimit,
      cvAccuracy: scores.isEmpty ? 0.5 : correct / scores.length,
      cvAuc: scores.isEmpty ? 0.5 : _auc(scores),
      trainedOn: (focus.length, rest.length),
      blocksUsed: (focusBlocks.length, restBlocks.length),
      blocksLeftOut: blocksLeftOut,
      windowsLeftOut: windowsLeftOut,
      created: now ?? DateTime.now(),
    );
  }

  /// Median plus three interquartile ranges.
  static double _limit(List<double> values) {
    final sorted = [...values]..sort();
    return _quantile(sorted, 0.5) + 3 * (_quantile(sorted, 0.75) - _quantile(sorted, 0.25));
  }

  static FocusModel? _fit(List<FocusWindow> focus, List<FocusWindow> rest) {
    if (focus.length < 2 || rest.length < 2) return null;
    final d = focus.first.features.length;
    final all = [...focus, ...rest];
    final center = Float64List(d), scale = Float64List(d);
    for (var j = 0; j < d; j++) {
      final values = [for (final w in all) w.features[j]]..sort();
      center[j] = _quantile(values, 0.5);
      final iqr = _quantile(values, 0.75) - _quantile(values, 0.25);
      scale[j] = iqr > 1e-9 ? iqr : 1;
    }
    Float64List scaled(FocusWindow w) =>
        Float64List.fromList([for (var j = 0; j < d; j++) (w.features[j] - center[j]) / scale[j]]);
    final x1 = [for (final w in focus) scaled(w)];
    final x0 = [for (final w in rest) scaled(w)];
    final m1 = _mean(x1, d), m0 = _mean(x0, d);
    final cov = _shrunkCovariance([
      for (final x in x1) Float64List.fromList([for (var j = 0; j < d; j++) x[j] - m1[j]]),
      for (final x in x0) Float64List.fromList([for (var j = 0; j < d; j++) x[j] - m0[j]]),
    ], d);
    final weights = _solve(cov, Float64List.fromList([for (var j = 0; j < d; j++) m1[j] - m0[j]]));
    var bias = 0.0;
    for (var j = 0; j < d; j++) {
      bias -= weights[j] * (m1[j] + m0[j]) / 2;
    }
    return FocusModel(
      center: center,
      scale: scale,
      weights: weights,
      bias: bias,
      muscleLimit: double.infinity,
      broadbandLimit: double.infinity,
      cvAccuracy: 0,
      cvAuc: 0,
      trainedOn: (focus.length, rest.length),
      blocksUsed: (0, 0),
      blocksLeftOut: 0,
      windowsLeftOut: 0,
      created: DateTime.now(),
    );
  }

  static Float64List _mean(List<Float64List> xs, int d) {
    final m = Float64List(d);
    for (final x in xs) {
      for (var j = 0; j < d; j++) {
        m[j] += x[j] / xs.length;
      }
    }
    return m;
  }

  /// Ledoit–Wolf shrinkage of the pooled within-class covariance towards a
  /// scaled identity: with a few hundred correlated windows and 36 features,
  /// the plain estimate is too noisy to invert reliably.
  static List<Float64List> _shrunkCovariance(List<Float64List> centred, int d) {
    final n = centred.length;
    final s = List.generate(d, (_) => Float64List(d));
    for (final x in centred) {
      for (var i = 0; i < d; i++) {
        for (var j = 0; j < d; j++) {
          s[i][j] += x[i] * x[j] / n;
        }
      }
    }
    var mu = 0.0;
    for (var i = 0; i < d; i++) {
      mu += s[i][i] / d;
    }
    var delta = 0.0;
    for (var i = 0; i < d; i++) {
      for (var j = 0; j < d; j++) {
        final v = s[i][j] - (i == j ? mu : 0);
        delta += v * v;
      }
    }
    var beta = 0.0;
    for (final x in centred) {
      for (var i = 0; i < d; i++) {
        for (var j = 0; j < d; j++) {
          final v = x[i] * x[j] - s[i][j];
          beta += v * v;
        }
      }
    }
    beta /= n * n;
    final shrink = delta <= 0 ? 1.0 : math.min(beta, delta) / delta;
    return [
      for (var i = 0; i < d; i++)
        Float64List.fromList([for (var j = 0; j < d; j++) (1 - shrink) * s[i][j] + (i == j ? shrink * mu : 0)]),
    ];
  }

  /// Solves a · x = b for symmetric positive-definite a (Cholesky).
  static Float64List _solve(List<Float64List> a, Float64List b) {
    final n = b.length;
    final l = List.generate(n, (_) => Float64List(n));
    for (var i = 0; i < n; i++) {
      for (var j = 0; j <= i; j++) {
        var sum = a[i][j];
        for (var k = 0; k < j; k++) {
          sum -= l[i][k] * l[j][k];
        }
        l[i][j] = i == j ? math.sqrt(math.max(sum, 1e-12)) : sum / l[j][j];
      }
    }
    final y = Float64List(n);
    for (var i = 0; i < n; i++) {
      var sum = b[i];
      for (var k = 0; k < i; k++) {
        sum -= l[i][k] * y[k];
      }
      y[i] = sum / l[i][i];
    }
    final x = Float64List(n);
    for (var i = n - 1; i >= 0; i--) {
      var sum = y[i];
      for (var k = i + 1; k < n; k++) {
        sum -= l[k][i] * x[k];
      }
      x[i] = sum / l[i][i];
    }
    return x;
  }

  static double _quantile(List<double> sorted, double q) {
    final pos = q * (sorted.length - 1);
    final lo = pos.floor(), hi = pos.ceil();
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }

  /// Probability a random focused window scores above a random resting one.
  static double _auc(List<(double, bool)> scores) {
    final sorted = [...scores]..sort((a, b) => a.$1.compareTo(b.$1));
    var rankSum = 0.0, positives = 0;
    var i = 0;
    while (i < sorted.length) {
      var j = i;
      while (j + 1 < sorted.length && sorted[j + 1].$1 == sorted[i].$1) {
        j++;
      }
      final rank = (i + j) / 2 + 1;
      for (var k = i; k <= j; k++) {
        if (sorted[k].$2) {
          rankSum += rank;
          positives++;
        }
      }
      i = j + 1;
    }
    final negatives = sorted.length - positives;
    if (positives == 0 || negatives == 0) return 0.5;
    return (rankSum - positives * (positives + 1) / 2) / (positives * negatives);
  }
}
