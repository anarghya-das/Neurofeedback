import 'dart:collection';

import 'package:eeg_viewer_lsl/utils/eeg_window_extractor.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a channel buffer whose x values are sample_index / [rate].
Queue<FlSpot> channel(List<double> values, {double rate = 10}) {
  final queue = Queue<FlSpot>();
  for (var i = 0; i < values.length; i++) {
    queue.add(FlSpot(i / rate, values[i]));
  }
  return queue;
}

void main() {
  test('packs the newest samples channel-major', () {
    final window = EegWindowExtractor.extract([
      channel([1, 2, 3, 4]),
      channel([10, 20, 30, 40]),
    ], samplesPerChannel: 3)!;

    expect(window.data, equals(<double>[2, 3, 4, 20, 30, 40]));
    expect(window.channelCount, 2);
    expect(window.samplesPerChannel, 3);
    expect(window.length, 6);
    expect(window.endTimeSeconds, closeTo(0.3, 1e-9));
    expect(window.spanSeconds, closeTo(0.2, 1e-9));
    expect(window.nonFiniteCount, 0);
  });

  test('returns null until every channel holds a full window', () {
    final window = EegWindowExtractor.extract([
      channel([1, 2, 3, 4]),
      channel([10, 20]),
    ], samplesPerChannel: 3);

    expect(window, isNull);
  });

  test('returns null when a requested channel does not exist', () {
    final channels = [
      channel([1, 2, 3]),
      channel([4, 5, 6]),
    ];

    expect(
      EegWindowExtractor.extract(
        channels,
        samplesPerChannel: 3,
        channelIndices: [0, 5],
      ),
      isNull,
    );
    expect(
      EegWindowExtractor.extract(
        channels,
        samplesPerChannel: 3,
        channelIndices: [-1],
      ),
      isNull,
    );
  });

  test('returns null without any channels', () {
    expect(
      EegWindowExtractor.extract(<Queue<FlSpot>>[], samplesPerChannel: 4),
      isNull,
    );
  });

  test('honors channel selection and order', () {
    final window = EegWindowExtractor.extract(
      [
        channel([1, 2, 3, 4]),
        channel([10, 20, 30, 40]),
      ],
      samplesPerChannel: 2,
      channelIndices: [1, 0],
    )!;

    expect(window.data, equals(<double>[30, 40, 3, 4]));
    expect(window.channelCount, 2);
  });

  test('replaces NaN and infinite samples with zero and counts them', () {
    final window = EegWindowExtractor.extract([
      channel([1, double.nan, 3, double.infinity]),
    ], samplesPerChannel: 4)!;

    expect(window.data, equals(<double>[1, 0, 3, 0]));
    expect(window.nonFiniteCount, 2);
  });

  test('samplesFor converts seconds to a sample count', () {
    expect(
      EegWindowExtractor.samplesFor(windowSeconds: 2, samplingRate: 256),
      512,
    );
    expect(
      EegWindowExtractor.samplesFor(windowSeconds: 0.5, samplingRate: 250),
      125,
    );
  });

  test('rejects a non-positive window length', () {
    expect(
      () => EegWindowExtractor.extract([
        channel([1, 2]),
      ], samplesPerChannel: 0),
      throwsArgumentError,
    );
  });
}
