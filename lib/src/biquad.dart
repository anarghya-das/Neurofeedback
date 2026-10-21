import 'dart:math' as math;
import 'dart:typed_data';

/// One second-order IIR section with a0 normalised to 1. Designs follow the
/// RBJ Audio EQ Cookbook (bilinear transform, prewarped at the cut-off), so
/// cascading Butterworth Q values gives an exact Butterworth response.
class Biquad {
  const Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory Biquad.lowPass(double cutoff, double rate, double q) {
    final (c, alpha) = _prewarp(cutoff, rate, q);
    final a0 = 1 + alpha;
    final b = (1 - c) / 2;
    return Biquad(b / a0, (1 - c) / a0, b / a0, -2 * c / a0, (1 - alpha) / a0);
  }

  factory Biquad.highPass(double cutoff, double rate, double q) {
    final (c, alpha) = _prewarp(cutoff, rate, q);
    final a0 = 1 + alpha;
    final b = (1 + c) / 2;
    return Biquad(b / a0, -(1 + c) / a0, b / a0, -2 * c / a0, (1 - alpha) / a0);
  }

  /// Removes [frequency]; the band it cuts is about [frequency] / [q] wide.
  factory Biquad.notch(double frequency, double rate, double q) {
    final (c, alpha) = _prewarp(frequency, rate, q);
    final a0 = 1 + alpha;
    return Biquad(1 / a0, -2 * c / a0, 1 / a0, -2 * c / a0, (1 - alpha) / a0);
  }

  final double b0, b1, b2, a1, a2;

  /// Gain for a constant input.
  double get dcGain => (b0 + b1 + b2) / (1 + a1 + a2);

  /// Q of each second-order section of an even-[order] Butterworth filter.
  static List<double> butterworthQs(int order) => [
    for (var k = 0; k < order ~/ 2; k++) 1 / (2 * math.cos((2 * k + 1) * math.pi / (2 * order))),
  ];

  /// Filters [x] in place (transposed direct form II), forwards or backwards,
  /// starting from the steady state for the first value so a DC offset does
  /// not ring at the start.
  void run(Float64List x, {bool forward = true}) {
    final n = x.length;
    if (n == 0) return;
    final state = BiquadState(this)..prime(forward ? x[0] : x[n - 1]);
    for (var k = 0; k < n; k++) {
      final i = forward ? k : n - 1 - k;
      x[i] = state.step(x[i]);
    }
  }

  static (double, double) _prewarp(double frequency, double rate, double q) {
    final w = 2 * math.pi * frequency / rate;
    return (math.cos(w), math.sin(w) / (2 * q));
  }
}

/// A [Biquad] applied one sample at a time, keeping its state between calls.
class BiquadState {
  BiquadState(this.coefficients);

  /// May be replaced while running (for example when the sample rate estimate
  /// improves); the state carries over, so the output stays continuous.
  Biquad coefficients;
  double _z1 = 0, _z2 = 0;
  bool _primed = false;

  /// Sets the state to where it would be had the input always been [x].
  void prime(double x) {
    final c = coefficients;
    final y = c.dcGain * x;
    _z2 = c.b2 * x - c.a2 * y;
    _z1 = c.b1 * x - c.a1 * y + _z2;
    _primed = true;
  }

  double step(double x) {
    if (!_primed) prime(x);
    final c = coefficients;
    final y = c.b0 * x + _z1;
    _z1 = c.b1 * x - c.a1 * y + _z2;
    _z2 = c.b2 * x - c.a2 * y;
    return y;
  }

  /// The next sample primes the state again.
  void reset() => _primed = false;
}
