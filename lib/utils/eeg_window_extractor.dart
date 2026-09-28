import 'dart:collection';
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';

import '../models/eeg_window.dart';

/// Cuts the newest samples out of the live EEG buffer
/// (`EEGDataManager.allChannelData`) and packs them into the flat,
/// channel-major [Float32List] a `ModelModule` consumes.
class EegWindowExtractor {
  const EegWindowExtractor._();

  /// Number of samples per channel that cover [windowSeconds] at
  /// [samplingRate].
  static int samplesFor({
    required double windowSeconds,
    required double samplingRate,
  }) => (windowSeconds * samplingRate).round();

  /// Returns the newest [samplesPerChannel] samples of every channel in
  /// [channelIndices] (default: all channels, in order), or `null` when the
  /// window cannot be built yet: no such channel, or a channel that holds fewer
  /// than [samplesPerChannel] samples.
  ///
  /// The x value of each [FlSpot] is graph time in seconds and the y value is
  /// the sample. Samples that are NaN or infinite are replaced with 0 and
  /// counted in [EegWindow.nonFiniteCount], so a bad sample cannot poison the
  /// model output.
  ///
  /// Throws [ArgumentError] if [samplesPerChannel] is not positive.
  static EegWindow? extract(
    List<Queue<FlSpot>> channels, {
    required int samplesPerChannel,
    List<int>? channelIndices,
  }) {
    if (samplesPerChannel <= 0) {
      throw ArgumentError.value(
        samplesPerChannel,
        'samplesPerChannel',
        'must be greater than 0',
      );
    }

    final indices =
        channelIndices ?? List<int>.generate(channels.length, (i) => i);
    if (indices.isEmpty) return null;

    for (final index in indices) {
      if (index < 0 || index >= channels.length) return null;
      if (channels[index].length < samplesPerChannel) return null;
    }

    final data = Float32List(indices.length * samplesPerChannel);
    var nonFiniteCount = 0;
    var startTime = 0.0;
    var endTime = 0.0;

    for (var c = 0; c < indices.length; c++) {
      final queue = channels[indices[c]];
      final base = c * samplesPerChannel;

      var i = 0;
      for (final spot in queue.skip(queue.length - samplesPerChannel)) {
        final value = spot.y;
        if (value.isFinite) {
          data[base + i] = value;
        } else {
          nonFiniteCount++;
        }

        if (c == 0) {
          if (i == 0) startTime = spot.x;
          endTime = spot.x;
        }
        i++;
      }
    }

    return EegWindow(
      data: data,
      channelCount: indices.length,
      samplesPerChannel: samplesPerChannel,
      endTimeSeconds: endTime,
      spanSeconds: endTime - startTime,
      nonFiniteCount: nonFiniteCount,
    );
  }
}
