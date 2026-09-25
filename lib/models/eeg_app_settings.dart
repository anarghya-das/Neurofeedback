class EegBandDefinition {
  EegBandDefinition({
    required this.name,
    required this.lowHz,
    required this.highHz,
  });

  final String name;
  final double lowHz;
  final double highHz;

  Map<String, dynamic> toJson() {
    return {'name': name, 'lowHz': lowHz, 'highHz': highHz};
  }

  factory EegBandDefinition.fromJson(Map<String, dynamic> json) {
    return EegBandDefinition(
      name: json['name'] as String? ?? '',
      lowHz: (json['lowHz'] as num?)?.toDouble() ?? 0.0,
      highHz: (json['highHz'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class EegAppSettings {
  EegAppSettings({
    required this.streamNameFilter,
    required this.expectedSamplingRate,
    required this.expectedChannelCount,
    required this.bufferSizeSeconds,
    required this.baselineDurationSeconds,
    required this.bands,
  });

  final String streamNameFilter;
  final double expectedSamplingRate;
  final int expectedChannelCount;
  final double bufferSizeSeconds;
  final double baselineDurationSeconds;
  final List<EegBandDefinition> bands;

  static EegAppSettings defaults() {
    return EegAppSettings(
      streamNameFilter: '',
      expectedSamplingRate: 256.0,
      expectedChannelCount: 8,
      bufferSizeSeconds: 10.0,
      baselineDurationSeconds: 15.0,
      bands: [
        EegBandDefinition(name: 'Delta', lowHz: 0.5, highHz: 4.0),
        EegBandDefinition(name: 'Theta', lowHz: 4.0, highHz: 8.0),
        EegBandDefinition(name: 'Alpha', lowHz: 8.0, highHz: 13.0),
        EegBandDefinition(name: 'Beta', lowHz: 13.0, highHz: 32.0),
        EegBandDefinition(name: 'Gamma', lowHz: 32.0, highHz: 100.0),
      ],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'streamNameFilter': streamNameFilter,
      'expectedSamplingRate': expectedSamplingRate,
      'expectedChannelCount': expectedChannelCount,
      'bufferSizeSeconds': bufferSizeSeconds,
      'baselineDurationSeconds': baselineDurationSeconds,
      'bands': bands.map((band) => band.toJson()).toList(),
    };
  }

  factory EegAppSettings.fromJson(Map<String, dynamic> json) {
    return EegAppSettings(
      streamNameFilter: json['streamNameFilter'] as String? ?? '',
      expectedSamplingRate:
          (json['expectedSamplingRate'] as num?)?.toDouble() ?? 256.0,
      expectedChannelCount:
          (json['expectedChannelCount'] as num?)?.toInt() ?? 8,
      bufferSizeSeconds:
          (json['bufferSizeSeconds'] as num?)?.toDouble() ?? 10.0,
      baselineDurationSeconds:
          (json['baselineDurationSeconds'] as num?)?.toDouble() ?? 15.0,
      bands: ((json['bands'] as List?) ?? [])
          .whereType<Map>()
          .map(
            (band) =>
                EegBandDefinition.fromJson(Map<String, dynamic>.from(band)),
          )
          .toList(),
    );
  }

  EegAppSettings copyWith({
    String? streamNameFilter,
    double? expectedSamplingRate,
    int? expectedChannelCount,
    double? bufferSizeSeconds,
    double? baselineDurationSeconds,
    List<EegBandDefinition>? bands,
  }) {
    return EegAppSettings(
      streamNameFilter: streamNameFilter ?? this.streamNameFilter,
      expectedSamplingRate: expectedSamplingRate ?? this.expectedSamplingRate,
      expectedChannelCount: expectedChannelCount ?? this.expectedChannelCount,
      bufferSizeSeconds: bufferSizeSeconds ?? this.bufferSizeSeconds,
      baselineDurationSeconds:
          baselineDurationSeconds ?? this.baselineDurationSeconds,
      bands: bands ?? this.bands,
    );
  }
}
