import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:eeg_viewer_lsl/models/eeg_window.dart';
import 'package:eeg_viewer_lsl/services/dummy_model_module.dart';
import 'package:eeg_viewer_lsl/services/eeg_inference_runner.dart';
import 'package:eeg_viewer_lsl/services/model_inference_service.dart';
import 'package:eeg_viewer_lsl/services/model_module.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';

const _spec = EegWindowSpec(
  channelCount: 2,
  samplesPerChannel: 64,
  samplingRate: 64,
);

const _timeout = Duration(seconds: 10);

ModelModule _fastModel() => DummyModelModule(spec: _spec);

/// Live-buffer stand-in: [samples] samples per channel at 64 Hz.
List<Queue<FlSpot>> _buffer(int samples, {int channels = 2}) {
  return List<Queue<FlSpot>>.generate(channels, (c) {
    final queue = Queue<FlSpot>();
    for (var i = 0; i < samples; i++) {
      queue.add(FlSpot(i / 64, 20 * math.sin(i * 0.5 + c)));
    }
    return queue;
  });
}

Future<ModelInferenceService> _startedService() async {
  final service = ModelInferenceService(factory: _fastModel);
  addTearDown(service.dispose);
  await service.start();
  return service;
}

void main() {
  test('submits a window, then waits for new samples', () async {
    final service = await _startedService();
    var channels = _buffer(64);
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => channels,
      samplingRateSource: () => 64,
    );

    final first = service.features.first;
    runner.tick();
    expect(runner.submittedCount, 1);
    final features = await first.timeout(_timeout);
    expect(features.windowEndSeconds, closeTo(63 / 64, 1e-9));

    // Same samples again: the stream has not advanced.
    runner.tick();
    expect(runner.staleCount, 1);
    expect(runner.submittedCount, 1);

    // One more sample arrived, so the newest window is different.
    channels = _buffer(65);
    final second = service.features.first;
    runner.tick();
    expect(runner.submittedCount, 2);
    await second.timeout(_timeout);
  });

  test('waits while the buffer is shorter than the model window', () async {
    final service = await _startedService();
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => _buffer(10),
      samplingRateSource: () => 64,
    );

    runner.tick();

    expect(runner.submittedCount, 0);
    expect(runner.waitingCount, 1);
  });

  test('skips ticks while the model is busy', () async {
    final service = ModelInferenceService(
      factory: () => DummyModelModule(
        spec: _spec,
        busyWork: const Duration(milliseconds: 200),
      ),
    );
    addTearDown(service.dispose);
    await service.start();

    var channels = _buffer(64);
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => channels,
      samplingRateSource: () => 64,
    );

    final first = service.features.first;
    runner.tick();
    channels = _buffer(65);
    runner.tick();

    expect(runner.submittedCount, 1);
    expect(runner.skippedBusyCount, 1);
    await first.timeout(_timeout);
  });

  test('refuses a stream whose sampling rate differs from the model', () async {
    final service = await _startedService();
    final problems = <String>[];
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => _buffer(64),
      samplingRateSource: () => 250,
      onProblem: problems.add,
    );

    runner.tick();
    runner.tick();

    expect(runner.submittedCount, 0);
    expect(problems, hasLength(1));
    expect(problems.single, contains('Hz'));
  });

  test('reports a channel count mismatch once', () async {
    final service = await _startedService();
    final problems = <String>[];
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => _buffer(64, channels: 1),
      samplingRateSource: () => 64,
      onProblem: problems.add,
    );

    runner.tick();
    runner.tick();

    expect(runner.submittedCount, 0);
    expect(problems, hasLength(1));
    expect(problems.single, contains('channels'));
  });

  test('warns when the buffer stops growing below the window size', () async {
    final service = await _startedService();
    final problems = <String>[];
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => _buffer(10),
      samplingRateSource: () => 64,
      onProblem: problems.add,
    );

    for (var i = 0; i < 12; i++) {
      runner.tick();
    }

    expect(runner.submittedCount, 0);
    expect(problems, hasLength(1));
    expect(problems.single, contains('not growing'));
  });

  test('timer-driven start and stop', () async {
    final service = await _startedService();
    final runner = EegInferenceRunner(
      service: service,
      channelSource: () => _buffer(64),
      samplingRateSource: () => 64,
      interval: const Duration(milliseconds: 20),
    );

    final next = service.features.first;
    runner.start();
    expect(runner.isRunning, isTrue);
    await next.timeout(_timeout);
    runner.stop();

    expect(runner.isRunning, isFalse);
    expect(runner.submittedCount, greaterThanOrEqualTo(1));
  });
}
