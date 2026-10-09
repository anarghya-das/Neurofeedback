import 'dart:collection';
import 'dart:math' as math;

import 'protocol.dart';

/// Values of the `sampleStatus` channel (the last one in the stream).
abstract final class SampleStatus {
  /// Measured by the headset and delivered.
  static const measured = 0;

  /// Lost over Bluetooth and filled by linear interpolation between the
  /// measured samples either side.
  static const interpolated = 1;

  /// Measured, but delivered after more than 0.5 s without data. The headset's
  /// 8-bit counter wraps every 256 samples (~0.5 s), so the number of samples
  /// lost before this one may be undercounted by multiples of 256.
  static const afterLongDropout = 2;
}

/// One output sample:
/// `[Ch1..Ch12 µV, Ref, DRL, lslCumulativeCounter, sampleStatus]`.
///
/// This matches Research Kit's 16-channel layout except the last channel, which
/// Research Kit uses for a CSV-recording counter (always 0 outside its own CSV
/// recording) and this driver uses for [SampleStatus].
class Mw75Sample {
  const Mw75Sample(this.values, this.time, {required this.status});

  final List<double> values;

  /// LSL clock seconds.
  final double time;

  /// One of [SampleStatus].
  final int status;

  bool get interpolated => status == SampleStatus.interpolated;
}

/// Turns decoded packets into evenly timestamped samples.
///
/// Mirrors Research Kit: lost packets (counter gaps) are filled by linear
/// interpolation, the cumulative counter advances by the gap, and an optional
/// 0.5 Hz high-pass removes DC offset. Unlike Research Kit, every sample says
/// whether it was measured or filled in (see [SampleStatus]), and timestamps
/// follow the headset's measured rate anchored to the earliest arrivals rather
/// than the moment of pushing, so Bluetooth burst jitter does not leak into them.
class Mw75StreamProcessor {
  Mw75StreamProcessor({this.interpolate = true, this.removeDcOffset = false});

  bool interpolate;
  bool removeDcOffset;

  static const channelCount = Mw75Protocol.eegChannelCount + 4;

  /// Longer than this without any packet and the counter can no longer be
  /// trusted to count what was lost (it wraps after 256 samples).
  static const longDropoutSeconds = 0.5;

  Mw75Packet? _previous;
  int _cumulative = 0;
  final _clock = _SampleClock(Mw75Protocol.samplingRate);
  final _dcFilters = List.generate(Mw75Protocol.eegChannelCount + 2, (_) => _HighPass());

  int received = 0;
  int lost = 0;
  int duplicates = 0;
  int longDropouts = 0;

  List<Mw75Sample> add(Mw75Packet packet) {
    final previous = _previous;
    var gap = 1;
    var longDropout = false;
    if (previous != null) {
      gap = (packet.counter - previous.counter) & 0xFF;
      if (gap == 0) {
        duplicates++;
        return const [];
      }
      lost += gap - 1;
      longDropout = packet.hostTime - previous.hostTime > longDropoutSeconds;
      if (longDropout) longDropouts++;
    }
    received++;
    _previous = packet;

    final out = <Mw75Sample>[];
    if (previous != null && gap > 1 && interpolate) {
      final from = _raw(previous);
      final to = _raw(packet);
      for (var k = 1; k < gap; k++) {
        final f = k / gap;
        final values = List<double>.generate(from.length, (i) => from[i] + (to[i] - from[i]) * f);
        out.add(_emit(values, _cumulative + k, packet.hostTime, SampleStatus.interpolated));
      }
    }
    _cumulative += previous == null ? 0 : gap;
    out.add(
      _emit(
        _raw(packet),
        _cumulative,
        packet.hostTime,
        longDropout ? SampleStatus.afterLongDropout : SampleStatus.measured,
      ),
    );
    return out;
  }

  void reset() {
    _previous = null;
    _cumulative = 0;
    _clock.reset();
    for (final f in _dcFilters) {
      f.reset();
    }
    received = 0;
    lost = 0;
    duplicates = 0;
    longDropouts = 0;
  }

  /// Fraction of packets the headset sent that never arrived.
  double get lossRatio => received + lost == 0 ? 0 : lost / (received + lost);

  /// Samples per second the headset actually delivers, once measured.
  double? get effectiveRate => _clock.effectiveRate;

  static List<double> _raw(Mw75Packet p) => [
    for (var c = 0; c < Mw75Protocol.eegChannelCount; c++) p.microvolts(c),
    p.ref,
    p.drl,
  ];

  Mw75Sample _emit(List<double> values, int index, double arrival, int status) {
    if (removeDcOffset) {
      for (var i = 0; i < values.length; i++) {
        values[i] = _dcFilters[i].apply(values[i]);
      }
    }
    // Research Kit writes 0 for non-finite values.
    for (var i = 0; i < values.length; i++) {
      if (!values[i].isFinite) values[i] = 0;
    }
    values
      ..add(index.toDouble())
      ..add(status.toDouble());
    return Mw75Sample(values, _clock.timeFor(index, arrival), status: status);
  }
}

/// Packet loss over a sliding window of cumulative (received, lost) snapshots,
/// so a session's slow start does not hide what is happening now.
class LossWindow {
  LossWindow({this.length = 40});

  /// Number of snapshots kept; at one snapshot per 250 ms, 40 is 10 s.
  final int length;
  final _snapshots = ListQueue<(int, int)>();

  void add(int received, int lost) {
    _snapshots.add((received, lost));
    while (_snapshots.length > length) {
      _snapshots.removeFirst();
    }
  }

  /// Lost / (received + lost) across the window, or null without data.
  double? get ratio {
    if (_snapshots.length < 2) return null;
    final (r0, l0) = _snapshots.first;
    final (r1, l1) = _snapshots.last;
    final total = (r1 - r0) + (l1 - l0);
    return total == 0 ? null : (l1 - l0) / total;
  }

  void clear() => _snapshots.clear();
}

/// Maps the cumulative sample index to LSL time.
///
/// The headset does not run at exactly 500 Hz: on the lab's MW75 the counter
/// advances ~496.5 times per real second, so assuming 500 Hz makes timestamps
/// fall ~8 ms behind real time every second. Instead, each second the most
/// promptly delivered packet is kept (a packet can only arrive after it was
/// sampled, so prompt arrivals trace the true sampling time plus a fixed
/// transport delay), and a line through the last 30 s of those points gives the
/// headset's real sample period. Until enough points exist, the nominal rate is
/// used with the earliest-arrival offset. Output is slew-limited so consecutive
/// timestamps never stall or jump.
class _SampleClock {
  _SampleClock(this.nominalRate);

  final double nominalRate;
  static const _bucketSeconds = 1.0;
  static const _windowSeconds = 30.0;
  static const _minPoints = 10;
  static const _maxRateError = 0.03;
  static const _backlogMargin = 0.15;
  static const _maxSlew = 0.05;
  static const _maxDriftPerSecond = 0.0005;

  // Earliest-arrival point per bucket: (index, arrival).
  final _points = <(int, double)>[];
  (int, double)? _bucketBest;
  double? _bucketStart;

  // Fitted line: arrival = _fitTime + (index - _fitIndex) * _period.
  double? _period;
  int _fitIndex = 0;
  double _fitTime = 0;

  // Fallback before a fit exists: nominal rate plus earliest-arrival offset.
  double? _base;
  double _offset = 0;
  double? _lastArrival;

  double? _lastOutput;
  int _lastIndex = 0;

  /// Measured samples per second, once 10 s of data have been seen.
  double? get effectiveRate => _period == null ? null : 1 / _period!;

  double timeFor(int index, double arrival) {
    _observe(index, arrival);
    final period = _period;
    final double target;
    if (period != null) {
      target = _fitTime + (index - _fitIndex) * period;
    } else {
      final base = _base ??= arrival - index / nominalRate;
      final nominal = base + index / nominalRate;
      final lateness = arrival - nominal;
      final last = _lastArrival;
      _offset = last == null
          ? lateness
          : math.min(lateness, _offset + _maxDriftPerSecond * math.max(0, arrival - last));
      _lastArrival = arrival;
      target = nominal + _offset;
    }
    final last = _lastOutput;
    final double out;
    if (last == null) {
      out = target;
    } else {
      final step = (index - _lastIndex) * (period ?? 1 / nominalRate);
      out = target.clamp(last + step * (1 - _maxSlew), last + step * (1 + _maxSlew));
    }
    _lastOutput = out;
    _lastIndex = index;
    return out;
  }

  void _observe(int index, double arrival) {
    final start = _bucketStart ??= arrival;
    if (arrival - start >= _bucketSeconds) {
      final best = _bucketBest;
      if (best != null) {
        if (_isMuchEarlierThanHistory(best)) {
          // Every earlier point was a backlog (the link was still waking up), so
          // none of them show the true transport delay. Start over.
          _points.clear();
          _period = null;
        }
        _points.add(best);
        while (_points.isNotEmpty && arrival - _points.first.$2 > _windowSeconds) {
          _points.removeAt(0);
        }
        _fit();
      }
      _bucketStart = arrival;
      _bucketBest = null;
    }
    final best = _bucketBest;
    if (best == null || _lateness(index, arrival) < _lateness(best.$1, best.$2)) {
      _bucketBest = (index, arrival);
    }
  }

  double _lateness(int index, double arrival) => arrival - index / nominalRate;

  /// A packet cannot arrive before it was sampled, so prompt arrivals can only
  /// get earlier (relative to the nominal clock) as fast as a ±3% clock error
  /// allows. Arriving much earlier than every point so far permits means those
  /// points were all late.
  bool _isMuchEarlierThanHistory((int, double) point) {
    if (_points.isEmpty) return false;
    final late = _lateness(point.$1, point.$2);
    for (final (n, t) in _points) {
      final allowed = _lateness(n, t) - _maxRateError * (point.$2 - t);
      if (late + _backlogMargin >= allowed) return false;
    }
    return true;
  }

  void _fit() {
    if (_points.length < _minPoints) return;
    // Siegel's repeated median: for each point, the median slope to every other
    // point; the period is the median of those. Up to half the points may be
    // late (the link waking up and delivering a backlog, or a stall) without
    // moving it, where least squares would be dragged towards a too-high rate.
    final ref = _points.last.$1;
    final perPoint = <double>[];
    for (final (ni, ti) in _points) {
      final slopes = [
        for (final (nj, tj) in _points)
          if (nj != ni) (tj - ti) / (nj - ni),
      ];
      if (slopes.isNotEmpty) perPoint.add(_median(slopes));
    }
    if (perPoint.isEmpty) return;
    final nominalPeriod = 1 / nominalRate;
    final period = _median(perPoint);
    // Outside ±3% of nominal the points are still dominated by the link waking
    // up; keep the previous estimate (or none) rather than report nonsense.
    if ((period - nominalPeriod).abs() > nominalPeriod * _maxRateError) return;
    _period = period;
    _fitIndex = ref;
    // Median intercept, for the same robustness.
    _fitTime = _median([for (final (n, t) in _points) t - (n - ref) * period]);
  }

  static double _median(List<double> values) {
    values.sort();
    final mid = values.length ~/ 2;
    return values.length.isOdd ? values[mid] : (values[mid - 1] + values[mid]) / 2;
  }

  void reset() {
    _points.clear();
    _bucketBest = null;
    _bucketStart = null;
    _period = null;
    _base = null;
    _offset = 0;
    _lastArrival = null;
    _lastOutput = null;
    _lastIndex = 0;
  }
}

/// First-order 0.5 Hz high-pass at 500 Hz, Research Kit's "DC offset" option.
class _HighPass {
  static const _alpha = 0.9937560466090253;
  double? _xPrev;
  double _yPrev = 0;

  double apply(double x) {
    final xPrev = _xPrev;
    final y = xPrev == null ? 0.0 : _alpha * (_yPrev + x - xPrev);
    _xPrev = x;
    _yPrev = y;
    return y;
  }

  void reset() {
    _xPrev = null;
    _yPrev = 0;
  }
}
