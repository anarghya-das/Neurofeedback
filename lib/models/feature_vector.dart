import 'dart:typed_data';

/// Abstract features a model derives from one EEG window (for example an
/// attentional-state score). This is what the visualization layer consumes.
class FeatureVector {
  FeatureVector({
    required this.values,
    this.labels = const <String>[],
    this.windowEndSeconds = 0.0,
    this.latencyMicros = 0,
    this.modelId = '',
  }) : assert(
         labels.isEmpty || labels.length == values.length,
         'labels must be empty or have one entry per value',
       );

  /// One value per feature. The scale is defined by the model; the bundled
  /// dummy model keeps everything in 0..1.
  final Float32List values;

  /// Optional feature names, parallel to [values].
  final List<String> labels;

  /// Graph time (seconds) of the newest EEG sample the features were computed
  /// from. Filled in by `ModelInferenceService`.
  final double windowEndSeconds;

  /// Time the model spent in `infer`, in microseconds. Filled in by
  /// `ModelInferenceService`.
  final int latencyMicros;

  /// Id of the `ModelModule` that produced this vector.
  final String modelId;

  int get length => values.length;

  double operator [](int index) => values[index];

  /// Value of the feature called [label], or `null` if there is no such label.
  double? valueOf(String label) {
    final index = labels.indexOf(label);
    return index < 0 ? null : values[index];
  }

  FeatureVector copyWith({
    Float32List? values,
    List<String>? labels,
    double? windowEndSeconds,
    int? latencyMicros,
    String? modelId,
  }) {
    return FeatureVector(
      values: values ?? this.values,
      labels: labels ?? this.labels,
      windowEndSeconds: windowEndSeconds ?? this.windowEndSeconds,
      latencyMicros: latencyMicros ?? this.latencyMicros,
      modelId: modelId ?? this.modelId,
    );
  }

  @override
  String toString() {
    final parts = <String>[];
    for (var i = 0; i < values.length; i++) {
      final name = i < labels.length ? labels[i] : '#$i';
      parts.add('$name=${values[i].toStringAsFixed(3)}');
    }
    return 'FeatureVector(${parts.join(', ')} '
        '@ ${windowEndSeconds.toStringAsFixed(2)}s, '
        '${(latencyMicros / 1000).toStringAsFixed(1)}ms, $modelId)';
  }
}
