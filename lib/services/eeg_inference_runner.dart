import 'dart:async';
import 'dart:collection';

import 'package:fl_chart/fl_chart.dart';

import '../utils/eeg_window_extractor.dart';
import 'model_inference_service.dart';

/// Feeds live EEG to a [ModelInferenceService] on a timer.
///
/// Every [interval] it cuts the newest window out of the EEG buffer and
/// submits it, unless the model is still busy, there is not enough data, or the
/// stream has not advanced. It only *reads* the buffer, so wiring it into the
/// screen does not touch the sample-processing path.
///
/// ```dart
/// _runner = EegInferenceRunner(
///   service: _inference,
///   channelSource: () => _dataManager.allChannelData,
///   samplingRateSource: () => _dataManager.samplingRate,
/// )..start();
/// ```
class EegInferenceRunner {
  EegInferenceRunner({
    required this.service,
    required this.channelSource,
    required this.samplingRateSource,
    this.interval = const Duration(milliseconds: 250),
    this.rateTolerance = 0.01,
    this.onProblem,
  });

  final ModelInferenceService service;

  /// Returns the live buffer, e.g. `() => dataManager.allChannelData`.
  final List<Queue<FlSpot>> Function() channelSource;

  /// Returns the stream's current sampling rate in Hz.
  final double Function() samplingRateSource;

  /// Time between window submissions.
  final Duration interval;

  /// Largest relative difference between the stream's sampling rate and the
  /// model's before windows are refused. Resampling is not implemented, and a
  /// mismatch would shift every frequency the model sees.
  final double rateTolerance;

  /// Called with a human-readable reason when windows cannot be submitted
  /// (channel or sampling-rate mismatch, buffer too small). Repeats of the
  /// same problem are reported once.
  final void Function(String message)? onProblem;

  /// After this many ticks without buffer growth while waiting for data, the
  /// "buffer not growing" problem is reported.
  static const int _stalledTicksBeforeWarning = 8;

  Timer? _timer;
  String? _lastProblem;
  double? _lastEndTime;
  int _lastLength = -1;
  int _stalledTicks = 0;
  List<int> _indices = const <int>[];

  int _submittedCount = 0;
  int _skippedBusyCount = 0;
  int _waitingCount = 0;
  int _staleCount = 0;

  bool get isRunning => _timer != null;

  /// Windows accepted by the service.
  int get submittedCount => _submittedCount;

  /// Ticks skipped because the model was still busy.
  int get skippedBusyCount => _skippedBusyCount;

  /// Ticks where the buffer did not yet hold a full window.
  int get waitingCount => _waitingCount;

  /// Ticks skipped because no new samples had arrived since the last window.
  int get staleCount => _staleCount;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Runs one submission attempt. Called by the timer; public so tests and
  /// callers can drive it directly.
  void tick() {
    if (!service.isRunning) return;
    final spec = service.inputSpec;
    if (spec == null) return;

    if (service.isBusy) {
      _skippedBusyCount++;
      return;
    }

    final rate = samplingRateSource();
    if (rate <= 0) return;
    if ((rate - spec.samplingRate).abs() / spec.samplingRate > rateTolerance) {
      _report(
        'Stream runs at ${rate.toStringAsFixed(1)} Hz but model '
        '"${service.modelId}" expects ${spec.samplingRate.toStringAsFixed(1)} '
        'Hz. Resampling is not implemented.',
      );
      return;
    }

    final channels = channelSource();
    if (channels.length < spec.channelCount) {
      _report(
        'Stream has ${channels.length} channels but model '
        '"${service.modelId}" expects ${spec.channelCount}.',
      );
      return;
    }

    if (_indices.length != spec.channelCount) {
      _indices = List<int>.generate(spec.channelCount, (i) => i);
    }

    final window = EegWindowExtractor.extract(
      channels,
      samplesPerChannel: spec.samplesPerChannel,
      channelIndices: _indices,
    );

    if (window == null) {
      _waitingCount++;
      _checkStalled(channels.first.length, spec.samplesPerChannel);
      return;
    }

    _stalledTicks = 0;
    _lastLength = -1;
    _clearProblem();

    // Equal end times mean the stream stopped and we would resubmit the same
    // window. A smaller end time is fine: the buffer was cleared and graph time
    // restarted (a new connection).
    if (window.endTimeSeconds == _lastEndTime) {
      _staleCount++;
      return;
    }

    if (service.submit(window.data, windowEndSeconds: window.endTimeSeconds)) {
      _submittedCount++;
      _lastEndTime = window.endTimeSeconds;
    }
  }

  void resetCounters() {
    _submittedCount = 0;
    _skippedBusyCount = 0;
    _waitingCount = 0;
    _staleCount = 0;
  }

  void _checkStalled(int currentLength, int needed) {
    if (currentLength == _lastLength) {
      _stalledTicks++;
    } else {
      _stalledTicks = 0;
      _lastLength = currentLength;
    }

    if (_stalledTicks >= _stalledTicksBeforeWarning) {
      _report(
        'Buffer holds $currentLength of $needed samples per channel and is '
        'not growing. Either the stream stopped or the buffer size in '
        'Configuration is shorter than the model window.',
      );
    }
  }

  void _report(String message) {
    if (message == _lastProblem) return;
    _lastProblem = message;
    onProblem?.call(message);
  }

  void _clearProblem() {
    _lastProblem = null;
  }
}
