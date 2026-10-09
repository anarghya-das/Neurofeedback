import 'dart:math' as math;

import 'protocol.dart';

/// Electrode contact rating, best to worst, as reported by Neurable Research Kit.
enum ContactQuality { best, good, acceptable, bad }

/// One signal-quality report covering a ~1 s window.
class Mw75SignalQuality {
  const Mw75SignalQuality({
    required this.ref,
    required this.drl,
    required this.channels,
  });

  /// Rated from the mean |Ref − DRL| difference; Research Kit reports the same
  /// value for both.
  final ContactQuality ref;
  final ContactQuality drl;

  /// One rating per EEG channel, `channels[0]` is Ch1.
  final List<ContactQuality> channels;

  static Mw75SignalQuality allBad() => Mw75SignalQuality(
    ref: ContactQuality.bad,
    drl: ContactQuality.bad,
    channels: List.filled(Mw75Protocol.eegChannelCount, ContactQuality.bad),
  );

  /// Same keys Research Kit emits to its UI.
  Map<String, String> toJson() => {
    'refQuality': ref.name,
    'drlQuality': drl.name,
    for (var i = 0; i < channels.length; i++) 'ch${i + 1}Quality': channels[i].name,
  };
}

/// Port of Research Kit's `ProtocolMW75::checkClipping`,
/// `updateMinAndMaxValues` and `addSignalQualities`.
///
/// Feed every packet to [add]; it returns a report each time at least
/// [window] seconds have passed since the window started, then starts a new one.
class Mw75SignalQualityEstimator {
  Mw75SignalQualityEstimator({this.window = 1.0});

  /// Window length in seconds.
  final double window;

  // Ref/DRL are 12-bit values; the EEG channels are 24-bit signed ADC counts.
  static const double _refDrlMax = 4095;
  static const double _adcMax = 8388607;
  static const double _adcMin = -8388608;
  static const double _maxClippedFraction = 0.25;

  // Mean |Ref − DRL| thresholds (ADC units).
  static const double _refDrlBest = 300;
  static const double _refDrlGood = 600;
  static const double _refDrlUsable = 1000;

  // Per-channel peak-to-peak thresholds over the window, in µV.
  static const double _p2pBest = 80;
  static const double _p2pGood = 180;
  static const double _p2pAcceptable = 280;

  double? _windowStart;
  final List<double> _refs = [];
  final List<double> _drls = [];
  int _refClipped = 0;
  int _drlClipped = 0;
  int _packets = 0;
  final List<int> _channelClipped = List.filled(Mw75Protocol.eegChannelCount, 0);
  final List<double> _min = List.filled(Mw75Protocol.eegChannelCount, double.maxFinite);
  final List<double> _max = List.filled(Mw75Protocol.eegChannelCount, -double.maxFinite);

  /// Adds one packet received at [time] (seconds, any monotonic clock).
  Mw75SignalQuality? add(Mw75Packet packet, double time) {
    final start = _windowStart;
    if (start == null) {
      // Research Kit discards the clipping counts of the packet that opens the
      // first window, so the window starts empty and then takes this packet's
      // min/max and Ref/DRL values.
      _reset(time);
      _updateMinMax(packet);
      return null;
    }

    _checkClipping(packet);
    _updateMinMax(packet);
    if (time - start < window) return null;

    final report = _evaluate();
    _reset(time);
    return report;
  }

  /// Forgets everything, e.g. after a reconnect.
  void clear() => _windowStart = null;

  void _checkClipping(Mw75Packet p) {
    if (p.ref <= 0 || p.ref >= _refDrlMax) _refClipped++;
    if (p.drl <= 0 || p.drl >= _refDrlMax) _drlClipped++;
    for (var i = 0; i < Mw75Protocol.eegChannelCount; i++) {
      final raw = p.rawChannels[i];
      if (raw <= _adcMin || raw >= _adcMax) _channelClipped[i]++;
    }
    _packets++;
  }

  void _updateMinMax(Mw75Packet p) {
    for (var i = 0; i < Mw75Protocol.eegChannelCount; i++) {
      final uv = p.microvolts(i);
      if (!uv.isFinite) continue;
      if (uv < _min[i]) _min[i] = uv;
      if (uv > _max[i]) _max[i] = uv;
    }
    if (p.ref.isFinite) _refs.add(p.ref);
    if (p.drl.isFinite) _drls.add(p.drl);
  }

  Mw75SignalQuality _evaluate() {
    final n = _refs.length;
    if (n == 0 || n != _drls.length) return Mw75SignalQuality.allBad();
    if (_refClipped / n >= _maxClippedFraction || _drlClipped / n >= _maxClippedFraction) {
      return Mw75SignalQuality.allBad();
    }

    var sum = 0.0;
    for (var k = 0; k < n; k++) {
      final d = (_refs[k] - _drls[k]).abs();
      if (!d.isFinite) return Mw75SignalQuality.allBad();
      sum += d;
    }
    final meanDiff = sum / n;
    if (meanDiff > _refDrlUsable) return Mw75SignalQuality.allBad();
    final refQuality = meanDiff < _refDrlBest
        ? ContactQuality.best
        : meanDiff < _refDrlGood
        ? ContactQuality.good
        : ContactQuality.acceptable;

    final channels = List.generate(Mw75Protocol.eegChannelCount, (i) {
      if (!_min[i].isFinite || !_max[i].isFinite) return ContactQuality.bad;
      if (_packets > 0 && _channelClipped[i] / _packets >= _maxClippedFraction) {
        return ContactQuality.bad;
      }
      // A channel with no finite samples keeps min = +max, max = -max, so p2p is
      // negative and rates "best" — the same as Research Kit.
      final p2p = _max[i] - _min[i];
      if (p2p <= _p2pBest) return ContactQuality.best;
      if (p2p <= _p2pGood) return ContactQuality.good;
      if (p2p <= _p2pAcceptable) return ContactQuality.acceptable;
      return ContactQuality.bad;
    });

    return Mw75SignalQuality(ref: refQuality, drl: refQuality, channels: channels);
  }

  void _reset(double time) {
    _windowStart = time;
    _refs.clear();
    _drls.clear();
    _refClipped = 0;
    _drlClipped = 0;
    _packets = 0;
    _channelClipped.fillRange(0, _channelClipped.length, 0);
    _min.fillRange(0, _min.length, double.maxFinite);
    _max.fillRange(0, _max.length, -double.maxFinite);
  }
}

/// Worst rating across Ref/DRL and all channels, for a one-glance summary.
ContactQuality worstQuality(Mw75SignalQuality q) => [q.ref, q.drl, ...q.channels]
    .reduce((a, b) => ContactQuality.values[math.max(a.index, b.index)]);

/// How many bad channels one ear cup may have before Research Kit calls its
/// general quality "bad".
enum QualityStrictness {
  strict('Strict', '0 bad sensors allowed', 0),
  standard('Standard', 'Max 1 bad sensor allowed', 1),
  lenient('Lenient', 'Max 3 bad sensors allowed', 3);

  const QualityStrictness(this.label, this.description, this.maxBad);

  final String label;
  final String description;
  final int maxBad;
}

/// The two ear cups. Ch1–Ch6 and both Ref electrodes sit in the left cushion,
/// Ch7–Ch12 and both DRL electrodes in the right (per Research Kit's layout).
enum EarSide { left, right }

/// Research Kit's per-cup summary: only the cup's six EEG channels count (Ref
/// and DRL are ignored), and the result is pass/fail: `best` unless more than
/// [strictness] allows are bad. `null` means no report yet ("checking").
ContactQuality? sideQuality(Mw75SignalQuality? quality, EarSide side, QualityStrictness strictness) {
  if (quality == null) return null;
  final first = side == EarSide.left ? 0 : 6;
  final bad = quality.channels.sublist(first, first + 6).where((q) => q == ContactQuality.bad).length;
  return bad > strictness.maxBad ? ContactQuality.bad : ContactQuality.best;
}
