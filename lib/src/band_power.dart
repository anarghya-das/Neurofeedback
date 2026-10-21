import 'dart:math' as math;
import 'dart:typed_data';

import 'protocol.dart';
import 'stream_processor.dart';

/// EEG frequency bands, with the edges and colours the lab's EEG Viewer uses so
/// the two apps report the same thing.
enum EegBand {
  delta('Delta', 0.5, 4, 0xFFF45B5B),
  theta('Theta', 4, 8, 0xFFE5C100),
  alpha('Alpha', 8, 13, 0xFF4F9A84),
  beta('Beta', 13, 32, 0xFF5D80BD),
  gamma('Gamma', 32, 100, 0xFF9A72AE);

  const EegBand(this.label, this.low, this.high, this.color);

  final String label;
  final double low;
  final double high;
  final int color;
}

/// Band power for one moment.
class BandPowers {
  const BandPowers({required this.density, required this.relative, required this.channelsUsed});

  /// Mean power spectral density in each band, µV²/Hz.
  final Map<EegBand, double> density;

  /// Share of 0.5–100 Hz power in each band (sums to 1).
  final Map<EegBand, double> relative;

  final int channelsUsed;
}

/// The mean power spectrum of some channels, for plotting.
class PowerSpectrum {
  const PowerSpectrum({required this.binHz, required this.density, required this.channelsUsed});

  /// Spacing of the bins: bin k is at k × [binHz] Hz.
  final double binHz;

  /// µV²/Hz per bin, from 0 Hz to half the sample rate.
  final Float64List density;
  final int channelsUsed;
}

/// Welch band power over the most recent ~2 s of each EEG channel.
///
/// Uses 512-sample Hann-windowed segments with 50% overlap and a linear detrend
/// per segment (the MW75's large, drifting DC offsets would otherwise leak into
/// delta). Interpolated samples are included: Welch needs evenly spaced data.
class BandPowerEstimator {
  BandPowerEstimator();

  static const segment = 512;
  static const _history = segment * 2;

  final _channels = List.generate(Mw75Protocol.eegChannelCount, (_) => Float64List(_history));
  int _filled = 0;
  int _head = 0;
  late final _fft = _Fft(segment);
  late final _window = Float64List.fromList([
    for (var i = 0; i < segment; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / (segment - 1)),
  ]);
  late final _windowPower = _window.fold<double>(0, (s, w) => s + w * w);

  void addAll(List<Mw75Sample> samples) {
    for (final s in samples) {
      for (var c = 0; c < _channels.length; c++) {
        _channels[c][_head] = s.values[c];
      }
      _head = (_head + 1) % _history;
      if (_filled < _history) _filled++;
    }
  }

  void clear() {
    _filled = 0;
    _head = 0;
  }

  /// Band powers averaged over [channels] (0-based EEG channel indices), or
  /// null until ~2 s of data have arrived.
  BandPowers? compute({required double sampleRate, required Iterable<int> channels}) {
    final spectrum = this.spectrum(sampleRate: sampleRate, channels: channels);
    if (spectrum == null) return null;
    final psd = spectrum.density;
    final df = spectrum.binHz;
    final power = <EegBand, double>{};
    var total = 0.0;
    for (final band in EegBand.values) {
      var sum = 0.0;
      for (var k = 0; k < psd.length; k++) {
        final f = k * df;
        if (f >= band.low && f < band.high) sum += psd[k] * df;
      }
      power[band] = sum;
      total += sum;
    }
    return BandPowers(
      density: {for (final b in EegBand.values) b: power[b]! / (b.high - b.low)},
      relative: {for (final b in EegBand.values) b: total == 0 ? 0 : power[b]! / total},
      channelsUsed: spectrum.channelsUsed,
    );
  }

  /// The Welch spectrum averaged over [channels], or null until ~2 s of data
  /// have arrived.
  PowerSpectrum? spectrum({required double sampleRate, required Iterable<int> channels}) {
    final each = spectra(sampleRate: sampleRate, channels: channels);
    if (each == null || each.isEmpty) return null;
    final psd = Float64List(each.first.density.length);
    for (final s in each) {
      for (var k = 0; k < psd.length; k++) {
        psd[k] += s.density[k] / each.length;
      }
    }
    return PowerSpectrum(binHz: each.first.binHz, density: psd, channelsUsed: each.length);
  }

  /// One Welch spectrum per channel in [channels], in the same order, or null
  /// until ~2 s of data have arrived.
  List<PowerSpectrum>? spectra({required double sampleRate, required Iterable<int> channels}) {
    if (_filled < _history) return null;
    const bins = segment ~/ 2 + 1;
    const starts = [0, segment ~/ 2, segment];
    final re = Float64List(segment);
    final im = Float64List(segment);
    final scale = 1 / (sampleRate * _windowPower);
    return [
      for (final c in channels)
        () {
          final data = _ordered(_channels[c]);
          final psd = Float64List(bins);
          for (final start in starts) {
            _detrendInto(data, start, re);
            for (var i = 0; i < segment; i++) {
              re[i] *= _window[i];
              im[i] = 0;
            }
            _fft.transform(re, im);
            for (var k = 0; k < bins; k++) {
              final p = (re[k] * re[k] + im[k] * im[k]) * scale;
              psd[k] += ((k == 0 || k == bins - 1) ? p : 2 * p) / starts.length;
            }
          }
          return PowerSpectrum(binHz: sampleRate / segment, density: psd, channelsUsed: 1);
        }(),
    ];
  }

  /// The ring buffer, oldest sample first.
  Float64List _ordered(Float64List ring) {
    final out = Float64List(_history);
    for (var i = 0; i < _history; i++) {
      out[i] = ring[(_head + i) % _history];
    }
    return out;
  }

  /// Copies one segment into [out] with its least-squares line removed.
  static void _detrendInto(List<double> data, int start, Float64List out) {
    const n = segment;
    const meanX = (n - 1) / 2;
    var meanY = 0.0;
    for (var i = 0; i < n; i++) {
      meanY += data[start + i];
    }
    meanY /= n;
    var sxy = 0.0, sxx = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = i - meanX;
      sxy += dx * (data[start + i] - meanY);
      sxx += dx * dx;
    }
    final slope = sxy / sxx;
    for (var i = 0; i < n; i++) {
      out[i] = data[start + i] - meanY - slope * (i - meanX);
    }
  }
}

/// The power spectrum of one [size]-sample segment, prepared the same way as
/// [BandPowerEstimator]'s: linear detrend, Hann window, one-sided density in
/// µV²/Hz. For callers that need a spectrum per segment rather than an average.
class SegmentSpectrum {
  static const size = BandPowerEstimator.segment;
  static const bins = size ~/ 2 + 1;

  final _fft = _Fft(size);
  final _re = Float64List(size);
  final _im = Float64List(size);
  late final _window = Float64List.fromList([
    for (var i = 0; i < size; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1)),
  ]);
  late final _windowPower = _window.fold<double>(0, (s, w) => s + w * w);

  /// Density at `k * sampleRate / size` Hz for k up to [bins] - 1, from
  /// `data[start] .. data[start + size - 1]`.
  Float64List psd(List<double> data, int start, double sampleRate) {
    BandPowerEstimator._detrendInto(data, start, _re);
    for (var i = 0; i < size; i++) {
      _re[i] *= _window[i];
      _im[i] = 0;
    }
    _fft.transform(_re, _im);
    final scale = 1 / (sampleRate * _windowPower);
    final out = Float64List(bins);
    for (var k = 0; k < bins; k++) {
      final p = (_re[k] * _re[k] + _im[k] * _im[k]) * scale;
      out[k] = (k == 0 || k == bins - 1) ? p : 2 * p;
    }
    return out;
  }
}

/// In-place iterative radix-2 FFT for one fixed power-of-two size.
class _Fft {
  _Fft(this.n)
    : _cos = Float64List(n ~/ 2),
      _sin = Float64List(n ~/ 2),
      _reverse = Int32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / n);
      _sin[i] = math.sin(-2 * math.pi * i / n);
    }
    final bits = (math.log(n) / math.ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _reverse[i] = r;
    }
  }

  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _reverse;

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _reverse[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size *= 2) {
      final half = size ~/ 2;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = _sin[k * step];
          final a = start + k;
          final b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}
