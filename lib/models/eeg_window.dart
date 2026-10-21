import 'dart:typed_data';

/// Shape of the EEG window a model expects as input.
///
/// The flat [Float32List] handed to `ModelModule.infer` uses a
/// **channel-major** layout: all samples of channel 0, followed by all samples
/// of channel 1, and so on. Sample `i` of channel `c` lives at index
/// `c * samplesPerChannel + i`.
class EegWindowSpec {
  const EegWindowSpec({
    required this.channelCount,
    required this.samplesPerChannel,
    required this.samplingRate,
  }) : assert(channelCount > 0),
       assert(samplesPerChannel > 0),
       assert(samplingRate > 0);

  final int channelCount;
  final int samplesPerChannel;

  /// Sampling rate (Hz) the model was designed for.
  final double samplingRate;

  /// Number of floats in a flat window.
  int get length => channelCount * samplesPerChannel;

  /// Duration covered by one window, in seconds.
  double get windowSeconds => samplesPerChannel / samplingRate;

  @override
  bool operator ==(Object other) =>
      other is EegWindowSpec &&
      other.channelCount == channelCount &&
      other.samplesPerChannel == samplesPerChannel &&
      other.samplingRate == samplingRate;

  @override
  int get hashCode => Object.hash(channelCount, samplesPerChannel, samplingRate);

  @override
  String toString() =>
      'EegWindowSpec($channelCount ch x $samplesPerChannel samples '
      '@ ${samplingRate}Hz)';
}

/// A window of EEG samples cut from the live buffer, ready for inference.
class EegWindow {
  const EegWindow({
    required this.data,
    required this.channelCount,
    required this.samplesPerChannel,
    required this.endTimeSeconds,
    required this.spanSeconds,
    this.nonFiniteCount = 0,
  });

  /// Channel-major samples, see [EegWindowSpec] for the layout.
  final Float32List data;
  final int channelCount;
  final int samplesPerChannel;

  /// Graph time (seconds) of the newest sample in the window.
  final double endTimeSeconds;

  /// Time between the first and last sample of the first channel. For a
  /// gap-free stream this is `(samplesPerChannel - 1) / samplingRate`; a larger
  /// value means samples were dropped inside the window.
  final double spanSeconds;

  /// Number of NaN/infinite samples that were replaced with 0.
  final int nonFiniteCount;

  int get length => data.length;
}
