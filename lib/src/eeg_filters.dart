import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'biquad.dart';

/// Which filters the live stream applies.
///
/// They are causal (each output uses only samples up to it), as they must be
/// for a live stream, so the band-pass shifts timing slightly; analyses that
/// depend on latency (the oddball test) use the unfiltered samples and their
/// own zero-phase filter instead.
@immutable
class EegFilterSettings {
  const EegFilterSettings({
    this.highPass = true,
    this.notch = true,
    this.mainsHz = 60,
    this.bandPass = false,
    this.bandLow = 1,
    this.bandHigh = 40,
    this.applyToLsl = false,
  });

  /// No filtering, for code that wants the samples as measured.
  static const off = EegFilterSettings(highPass: false, notch: false, bandPass: false);

  /// Research Kit's 0.5 Hz "DC offset" high-pass (first order), which removes
  /// the electrodes' large, slowly drifting offsets.
  final bool highPass;
  static const highPassHz = 0.5;

  /// Removes mains interference at [mainsHz] and its second harmonic.
  final bool notch;

  /// 60 Hz in the Americas, 50 Hz in most other places.
  final double mainsHz;

  /// Butterworth band-pass: 2nd-order high-pass at [bandLow], 4th-order
  /// low-pass at [bandHigh].
  final bool bandPass;
  final double bandLow;
  final double bandHigh;

  /// Whether the LSL stream carries the filtered EEG. Off by default: LSL
  /// carries the EEG as measured (what recorders and analysis tools expect)
  /// and only the app's plots are filtered.
  final bool applyToLsl;

  static const mainsOptions = [60.0, 50.0];
  static const bandLowOptions = [0.1, 0.5, 1.0, 2.0, 4.0];
  static const bandHighOptions = [15.0, 20.0, 30.0, 40.0, 45.0, 70.0, 100.0];

  /// Notch width: the band cut is about mains / q wide (3 Hz at 60 Hz).
  static const notchQ = 20.0;

  bool get any => highPass || notch || bandPass;

  /// "0.5 Hz high-pass, 60 Hz notch", or "none".
  String describe() {
    String hz(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();
    final parts = [
      if (highPass) '${hz(highPassHz)} Hz high-pass',
      if (notch) '${hz(mainsHz)} Hz notch',
      if (bandPass) '${hz(bandLow)}–${hz(bandHigh)} Hz band-pass',
    ];
    return parts.isEmpty ? 'none' : parts.join(', ');
  }

  EegFilterSettings copyWith({
    bool? highPass,
    bool? notch,
    double? mainsHz,
    bool? bandPass,
    double? bandLow,
    double? bandHigh,
    bool? applyToLsl,
  }) => EegFilterSettings(
    highPass: highPass ?? this.highPass,
    notch: notch ?? this.notch,
    mainsHz: mainsHz ?? this.mainsHz,
    bandPass: bandPass ?? this.bandPass,
    bandLow: bandLow ?? this.bandLow,
    bandHigh: bandHigh ?? this.bandHigh,
    applyToLsl: applyToLsl ?? this.applyToLsl,
  );

  @override
  bool operator ==(Object other) =>
      other is EegFilterSettings &&
      other.highPass == highPass &&
      other.notch == notch &&
      other.mainsHz == mainsHz &&
      other.bandPass == bandPass &&
      other.bandLow == bandLow &&
      other.bandHigh == bandHigh &&
      other.applyToLsl == applyToLsl;

  @override
  int get hashCode => Object.hash(highPass, notch, mainsHz, bandPass, bandLow, bandHigh, applyToLsl);
}

/// Applies [EegFilterSettings] sample by sample to a fixed number of channels.
///
/// The notch and band-pass are designed for the headset's measured sample
/// rate: it runs at ~496.5 Hz rather than 500, and a narrow notch designed for
/// 500 Hz would sit 0.4 Hz off the mains frequency and remove only part of it.
/// [rate] can be updated as the estimate improves without resetting state.
class EegFilterBank {
  EegFilterBank(this.settings, {required double rate, required this.eegChannels, this.extraChannels = 0})
    : _rate = rate {
    final total = eegChannels + extraChannels;
    _highPass = List.generate(total, (_) => _FirstOrderHighPass());
    _sections = List.generate(eegChannels, (_) => [for (final b in _design(rate)) BiquadState(b)]);
  }

  final EegFilterSettings settings;

  /// Channels that get every filter.
  final int eegChannels;

  /// Channels after them that only get the high-pass (Ref and DRL, as in
  /// Research Kit's DC-offset option).
  final int extraChannels;

  double get rate => _rate;
  double _rate;

  /// Where the notch sits, in cycles per sample, once [MainsTracker] has found
  /// the interference; until then it is mains Hz / [rate].
  double? get notchCenter => _notchCenter;
  double? _notchCenter;
  late final List<_FirstOrderHighPass> _highPass;
  late List<List<BiquadState>> _sections;

  /// Filters the first [eegChannels] + [extraChannels] values in place.
  void filter(List<double> values) {
    if (settings.highPass) {
      for (var i = 0; i < _highPass.length; i++) {
        values[i] = _highPass[i].apply(values[i]);
      }
    }
    for (var c = 0; c < eegChannels; c++) {
      var v = values[c];
      for (final s in _sections[c]) {
        v = s.step(v);
      }
      values[c] = v;
    }
  }

  /// Redesigns for a better sample-rate estimate, keeping the filter state.
  void updateRate(double rate) {
    if ((rate - _rate).abs() <= _rate * 5e-4) return;
    _rate = rate;
    _redesign();
  }

  /// Centres the notch on [cyclesPerSample] (and its harmonic on twice that),
  /// keeping the filter state.
  void setNotchCenter(double cyclesPerSample) {
    _notchCenter = cyclesPerSample;
    _redesign();
  }

  void _redesign() {
    final designs = _design(_rate);
    if (designs.length != _sections.first.length) {
      _sections = List.generate(eegChannels, (_) => [for (final b in designs) BiquadState(b)]);
      return;
    }
    for (final channel in _sections) {
      for (var i = 0; i < channel.length; i++) {
        channel[i].coefficients = designs[i];
      }
    }
  }

  List<Biquad> _design(double rate) {
    final nyquist = rate / 2;
    // In cycles per sample, so a measured centre needs no rate at all.
    final center = _notchCenter ?? settings.mainsHz / rate;
    return [
      if (settings.notch)
        for (final nu in [center, 2 * center])
          if (nu < 0.5 * 0.95) Biquad.notch(nu, 1, EegFilterSettings.notchQ),
      if (settings.bandPass) ...[
        Biquad.highPass(settings.bandLow, rate, Biquad.butterworthQs(2).single),
        if (settings.bandHigh < nyquist * 0.95)
          for (final q in Biquad.butterworthQs(4)) Biquad.lowPass(settings.bandHigh, rate, q),
      ],
    ];
  }
}

/// Finds where mains interference actually sits in the sample stream.
///
/// The host's estimate of the headset's sample rate and the headset's real
/// clock disagree slightly: on the lab headset, 60 Hz mains lands at 0.1204
/// cycles per sample, which the estimated ~496.2 Hz rate calls 59.7–59.8 Hz.
/// A notch a few hertz wide aimed at exactly 60 Hz then removes only part of
/// it. So every [every] samples this scans ±3% around where mains is expected,
/// over the last [window] samples of every channel, and reports the peak
/// when it stands at least 10 dB above its surroundings.
class MainsTracker {
  MainsTracker({this.channels = 12})
    : _buffers = List.generate(channels, (_) => Float64List(window));

  static const window = 4096;
  static const every = 1024;
  static const _range = 0.03;
  static const _prominence = 10.0;

  final int channels;
  final List<Float64List> _buffers;
  int _head = 0;
  int _filled = 0;
  int _sinceScan = 0;
  late final _taper = Float64List.fromList([
    for (var i = 0; i < window; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / (window - 1)),
  ]);

  /// The interference's frequency in cycles per sample, once found.
  double? get cyclesPerSample => _found;
  double? _found;

  /// Adds one sample (the first [channels] values). Returns true when a scan
  /// just updated [cyclesPerSample]. [expected] is mains Hz / sample rate.
  bool add(List<double> values, {required double expected}) {
    for (var c = 0; c < channels; c++) {
      _buffers[c][_head] = values[c];
    }
    _head = (_head + 1) % window;
    if (_filled < window) _filled++;
    if (++_sinceScan < every || _filled < window) return false;
    _sinceScan = 0;
    final found = _scan(expected);
    if (found == null) return false;
    _found = found;
    return true;
  }

  double? _scan(double expected) {
    // Hann-tapered, mean-removed copies, oldest sample first.
    final data = [
      for (final ring in _buffers)
        () {
          var mean = 0.0;
          for (final v in ring) {
            mean += v;
          }
          mean /= window;
          return Float64List.fromList([
            for (var i = 0; i < window; i++) (ring[(_head + i) % window] - mean) * _taper[i],
          ]);
        }(),
    ];
    // Quarter-bin steps across the range; power summed over channels.
    const step = 0.25 / window;
    final from = expected * (1 - _range);
    final count = (2 * _range * expected / step).ceil() + 1;
    final power = Float64List(count);
    for (var j = 0; j < count; j++) {
      final coeff = 2 * math.cos(2 * math.pi * (from + j * step));
      var total = 0.0;
      for (final x in data) {
        // Goertzel: the DFT power at one frequency.
        var s1 = 0.0, s2 = 0.0;
        for (var i = 0; i < window; i++) {
          final s0 = x[i] + coeff * s1 - s2;
          s2 = s1;
          s1 = s0;
        }
        total += s1 * s1 + s2 * s2 - coeff * s1 * s2;
      }
      power[j] = total;
    }
    var best = 1;
    for (var j = 1; j < count - 1; j++) {
      if (power[j] > power[best]) best = j;
    }
    final sorted = [...power]..sort();
    final median = sorted[count ~/ 2];
    if (median <= 0 || power[best] < _prominence * median || best == 0 || best == count - 1) return null;
    // Parabolic interpolation on log power for the exact top.
    final a = math.log(power[best - 1]), b = math.log(power[best]), c = math.log(power[best + 1]);
    final offset = 0.5 * (a - c) / (a - 2 * b + c);
    return from + (best + offset.clamp(-1.0, 1.0)) * step;
  }
}

/// Research Kit's first-order 0.5 Hz high-pass ("DC offset"); the coefficient
/// is RC / (RC + 1/500 s) with RC = 1 / (2π · 0.5 Hz), copied exactly so the
/// output matches Research Kit's.
class _FirstOrderHighPass {
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
}
