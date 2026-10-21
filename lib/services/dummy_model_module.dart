import 'dart:math' as math;
import 'dart:typed_data';

import '../models/eeg_window.dart';
import '../models/feature_vector.dart';
import 'model_module.dart';

/// Placeholder model that needs no weights.
///
/// It derives three cheap signal statistics from the window and squashes them
/// into 0..1, so the pipeline and the visualization can be developed and
/// tested before a real model exists. The numbers carry **no physiological
/// meaning**.
///
/// * `energy`: RMS amplitude of the DC-removed signal.
/// * `roughness`: mean absolute sample-to-sample change.
/// * `balance`: share of power in the first half of the channels
///   (0.5 = equal, or a flat signal).
class DummyModelModule implements ModelModule {
  DummyModelModule({
    EegWindowSpec? spec,
    this.busyWork = Duration.zero,
    this.referenceMicrovolts = 50.0,
  }) : inputSpec =
           spec ??
           const EegWindowSpec(
             channelCount: 8,
             samplesPerChannel: 512,
             samplingRate: 256,
           );

  static const List<String> featureLabels = <String>[
    'energy',
    'roughness',
    'balance',
  ];

  /// Burns CPU inside [infer] for this long. Useful to show that a slow model
  /// does not block the UI thread.
  final Duration busyWork;

  /// Amplitude (uV) that maps to 0.5 on the `energy` / `roughness` scales.
  final double referenceMicrovolts;

  @override
  final EegWindowSpec inputSpec;

  @override
  String get id => 'dummy';

  @override
  Future<void> load() async {}

  @override
  FeatureVector infer(Float32List window) {
    if (window.length != inputSpec.length) {
      throw ArgumentError.value(
        window.length,
        'window.length',
        'expected ${inputSpec.length} values '
            '(${inputSpec.channelCount} channels x '
            '${inputSpec.samplesPerChannel} samples)',
      );
    }

    if (busyWork > Duration.zero) {
      final watch = Stopwatch()..start();
      while (watch.elapsed < busyWork) {}
    }

    final channels = inputSpec.channelCount;
    final n = inputSpec.samplesPerChannel;
    final half = channels ~/ 2;

    var powerSum = 0.0;
    var roughnessSum = 0.0;
    var firstHalfPower = 0.0;
    var secondHalfPower = 0.0;

    for (var c = 0; c < channels; c++) {
      final base = c * n;

      var mean = 0.0;
      for (var i = 0; i < n; i++) {
        mean += window[base + i];
      }
      mean /= n;

      var previous = window[base] - mean;
      var power = previous * previous;
      var roughness = 0.0;
      for (var i = 1; i < n; i++) {
        final x = window[base + i] - mean;
        power += x * x;
        roughness += (x - previous).abs();
        previous = x;
      }
      power /= n;
      roughness /= n > 1 ? n - 1 : 1;

      powerSum += power;
      roughnessSum += roughness;
      if (c < half) {
        firstHalfPower += power;
      } else {
        secondHalfPower += power;
      }
    }

    final rms = _sqrt(powerSum / channels);
    final meanRoughness = roughnessSum / channels;
    final totalHalfPower = firstHalfPower + secondHalfPower;

    return FeatureVector(
      values: Float32List.fromList(<double>[
        _squash(rms / referenceMicrovolts),
        _squash(meanRoughness / referenceMicrovolts),
        totalHalfPower > 0 ? firstHalfPower / totalHalfPower : 0.5,
      ]),
      labels: featureLabels,
      modelId: id,
    );
  }

  @override
  void dispose() {}

  /// Maps [0, inf) to [0, 1) with 1 -> 0.5. Non-finite input maps to 0.
  static double _squash(double x) => x.isFinite && x > 0 ? x / (1 + x) : 0.0;

  static double _sqrt(double x) => x.isFinite && x > 0 ? math.sqrt(x) : 0.0;
}

/// Top-level factory for [DummyModelModule]. Top-level functions can be sent to
/// the inference isolate, closures over widget state cannot.
ModelModule createDummyModelModule() => DummyModelModule();
