import 'dart:async';
import 'dart:typed_data';

import '../models/eeg_window.dart';
import '../models/feature_vector.dart';

/// Pluggable inference backend: EEG window in, abstract features out.
///
/// A module lives entirely inside the background isolate that
/// `ModelInferenceService` spawns, so it never touches the UI thread:
///
/// 1. the service calls the [ModelModuleFactory] inside the isolate,
/// 2. then [load] (create the ONNX / TFLite session here, native handles cannot
///    be sent between isolates),
/// 3. then [infer] for every window,
/// 4. and finally [dispose].
///
/// To add a real backend, `implements ModelModule` and expose a top-level
/// factory function for it (see `createDummyModelModule`).
abstract class ModelModule {
  /// Short identifier that is stamped on every `FeatureVector`.
  String get id;

  /// Window shape this model consumes.
  EegWindowSpec get inputSpec;

  /// Loads weights / creates the runtime session. Called once, before the
  /// first [infer].
  Future<void> load();

  /// Runs the model on one window laid out as described by [inputSpec]
  /// (channel-major). `window.length` always equals `inputSpec.length`.
  ///
  /// The returned vector only needs `values` (and optionally `labels`); the
  /// service fills in the window time, latency and model id.
  FutureOr<FeatureVector> infer(Float32List window);

  /// Releases whatever [load] acquired.
  void dispose();
}

/// Creates a [ModelModule] inside the inference isolate.
///
/// Must be a top-level function or a static method. A closure that captures
/// non-sendable state (widgets, controllers, `this`) cannot cross the isolate
/// boundary.
typedef ModelModuleFactory = ModelModule Function();
