import 'dart:math' as math;

import '../models/eeg_app_settings.dart';

/// Converts FFT amplitude-density bins (µV/√Hz) into mean PSD (µV²/Hz)
/// for each configured frequency range.
List<double> configuredBandPower({
  required List<double> amplitudeBins,
  required double binsPerHz,
  required List<EegBandDefinition> bands,
}) {
  if (amplitudeBins.isEmpty || binsPerHz <= 0) {
    return List<double>.filled(bands.length, 1e-6);
  }

  return bands.map((band) {
    final firstBin = math.max(0, (band.lowHz * binsPerHz).ceil());
    final endBin = math.min(
      amplitudeBins.length,
      (band.highHz * binsPerHz).ceil(),
    );

    if (firstBin >= endBin) return 1e-6;

    var powerSum = 0.0;
    var count = 0;
    for (var bin = firstBin; bin < endBin; bin++) {
      final amplitude = amplitudeBins[bin];
      if (!amplitude.isFinite) continue;
      powerSum += amplitude * amplitude;
      count++;
    }

    return count == 0 ? 1e-6 : math.max(1e-6, powerSum / count);
  }).toList();
}
