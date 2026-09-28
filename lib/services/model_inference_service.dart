import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import '../models/eeg_window.dart';
import '../models/feature_vector.dart';
import 'model_module.dart';

/// Problem reported by [ModelInferenceService]: thrown by `start()` when the
/// model cannot be loaded, and emitted on [ModelInferenceService.errors] for
/// failures while running.
class InferenceException implements Exception {
  const InferenceException(this.message, [this.details]);

  final String message;

  /// Stack trace or other diagnostic text from the inference isolate.
  final String? details;

  @override
  String toString() => details == null
      ? 'InferenceException: $message'
      : 'InferenceException: $message\n$details';
}

enum _ServiceState { stopped, starting, running, stopping }

/// Runs a [ModelModule] in a background isolate so inference never blocks the
/// UI thread, and publishes the resulting [FeatureVector]s as a stream.
///
/// ```dart
/// final service = ModelInferenceService(factory: createDummyModelModule);
/// await service.start();
/// service.features.listen((features) { /* update the visualization */ });
/// service.submit(window.data, windowEndSeconds: window.endTimeSeconds);
/// ...
/// await service.dispose();
/// ```
///
/// The service handles one window at a time. While the model is busy,
/// [submit] drops the new window and returns `false`: for a live display the
/// newest data matters more than a growing backlog.
class ModelInferenceService {
  ModelInferenceService({
    required ModelModuleFactory factory,
    this.loadTimeout = const Duration(seconds: 30),
    this.stopTimeout = const Duration(seconds: 2),
  }) : _factory = factory;

  final ModelModuleFactory _factory;

  /// How long `start()` waits for the model to load.
  final Duration loadTimeout;

  /// How long `stop()` waits for a clean exit before killing the isolate.
  final Duration stopTimeout;

  final StreamController<FeatureVector> _features =
      StreamController<FeatureVector>.broadcast();
  final StreamController<InferenceException> _errors =
      StreamController<InferenceException>.broadcast();

  _ServiceState _state = _ServiceState.stopped;
  Future<void>? _startFuture;
  bool _disposed = false;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _replies;
  ReceivePort? _crashes;
  ReceivePort? _exits;
  Completer<void>? _exitSignal;

  EegWindowSpec? _inputSpec;
  String? _modelId;
  int _nextRequestId = 0;
  bool _inFlight = false;
  int _completedCount = 0;
  int _droppedCount = 0;
  int _failedCount = 0;

  /// Feature vectors, one per completed window (broadcast stream).
  Stream<FeatureVector> get features => _features.stream;

  /// Failures while running, e.g. the model threw on a window or the isolate
  /// died (broadcast stream).
  Stream<InferenceException> get errors => _errors.stream;

  bool get isRunning => _state == _ServiceState.running;

  /// `true` while a window is being processed; [submit] would drop a window.
  bool get isBusy => _inFlight;

  /// Window shape the loaded model expects, `null` until [start] completes.
  EegWindowSpec? get inputSpec => _inputSpec;

  String? get modelId => _modelId;

  /// Windows that produced a feature vector since the last [start].
  int get completedCount => _completedCount;

  /// Windows rejected by [submit] because the model was still busy.
  int get droppedCount => _droppedCount;

  /// Windows for which the model threw.
  int get failedCount => _failedCount;

  /// Spawns the isolate and loads the model. Completes when [submit] can be
  /// used. Throws [InferenceException] if the model cannot be loaded. Calling
  /// it again while starting or running is harmless.
  Future<void> start() {
    if (_disposed) {
      return Future<void>.error(
        StateError('ModelInferenceService has been disposed'),
      );
    }
    if (_state == _ServiceState.running) return Future<void>.value();

    final pending = _startFuture;
    if (pending != null) return pending;

    if (_state == _ServiceState.stopping) {
      return Future<void>.error(
        StateError('Cannot start while the service is stopping'),
      );
    }

    final future = _doStart().whenComplete(() => _startFuture = null);
    _startFuture = future;
    return future;
  }

  /// Offers [window] (layout: see [EegWindowSpec]) to the model. Returns `true`
  /// if it was accepted, `false` if it was dropped because the service is not
  /// running or the model is still busy with the previous window.
  ///
  /// [windowEndSeconds] is copied onto the resulting [FeatureVector]. The
  /// window is copied to the isolate, so the caller may reuse the buffer.
  ///
  /// Throws [ArgumentError] if the window has the wrong size for the model.
  bool submit(Float32List window, {double windowEndSeconds = 0.0}) {
    final spec = _inputSpec;
    final commands = _commands;
    if (_state != _ServiceState.running || spec == null || commands == null) {
      return false;
    }

    if (window.length != spec.length) {
      throw ArgumentError.value(
        window.length,
        'window.length',
        'model "$_modelId" expects ${spec.length} values '
            '(${spec.channelCount} channels x ${spec.samplesPerChannel} '
            'samples)',
      );
    }

    if (_inFlight) {
      _droppedCount++;
      return false;
    }

    _inFlight = true;
    commands.send(_InferRequest(++_nextRequestId, windowEndSeconds, window));
    return true;
  }

  /// Shuts the isolate down. The service can be started again afterwards.
  Future<void> stop() async {
    final starting = _startFuture;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // A failed start already cleaned up after itself.
      }
    }

    if (_state == _ServiceState.stopped || _state == _ServiceState.stopping) {
      return;
    }
    _state = _ServiceState.stopping;

    final isolate = _isolate;
    final exitSignal = _exitSignal;
    _commands?.send(const _Shutdown());

    if (exitSignal != null) {
      try {
        await exitSignal.future.timeout(stopTimeout);
      } on TimeoutException {
        isolate?.kill(priority: Isolate.immediate);
      }
    } else {
      isolate?.kill(priority: Isolate.immediate);
    }

    _releaseWorker();
    _state = _ServiceState.stopped;
  }

  /// Stops the isolate and closes the streams. The service cannot be reused.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _features.close();
    await _errors.close();
  }

  Future<void> _doStart() async {
    _state = _ServiceState.starting;
    _completedCount = 0;
    _droppedCount = 0;
    _failedCount = 0;
    _inFlight = false;

    final replies = ReceivePort();
    final crashes = ReceivePort();
    final exits = ReceivePort();
    final exitSignal = Completer<void>();
    final ready = Completer<_WorkerReady>();
    // The worker may fail before we start awaiting `ready`; without this the
    // early error would be reported as unhandled. Later awaits still see it.
    ready.future.ignore();
    _replies = replies;
    _crashes = crashes;
    _exits = exits;
    _exitSignal = exitSignal;

    replies.listen((Object? message) {
      if (message is _WorkerReady) {
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is _WorkerLoadFailed) {
        if (!ready.isCompleted) {
          ready.completeError(
            InferenceException(
              'Model failed to load: ${message.error}',
              message.stack,
            ),
          );
        }
      } else if (message is _InferResult) {
        _onResult(message);
      } else if (message is _InferFailure) {
        _onFailure(message);
      }
    });

    crashes.listen((Object? message) {
      // Uncaught error in the worker: a List of [error, stackTrace].
      final details = message is List ? message.join('\n') : '$message';
      final exception = InferenceException(
        'Inference isolate crashed',
        details,
      );
      if (_state == _ServiceState.starting) {
        if (!ready.isCompleted) ready.completeError(exception);
      } else {
        _onWorkerDied(exception);
      }
    });

    exits.listen((Object? _) {
      if (!exitSignal.isCompleted) exitSignal.complete();
      if (_state == _ServiceState.running) {
        _onWorkerDied(
          const InferenceException('Inference isolate exited unexpectedly'),
        );
      } else if (_state == _ServiceState.starting && !ready.isCompleted) {
        ready.completeError(
          const InferenceException(
            'Inference isolate exited before the model was ready',
          ),
        );
      }
    });

    try {
      _isolate = await Isolate.spawn<_WorkerInit>(
        _inferenceWorkerMain,
        _WorkerInit(replies.sendPort, _factory),
        onError: crashes.sendPort,
        onExit: exits.sendPort,
        debugName: 'model-inference',
      );
    } catch (error) {
      _abortStart();
      throw InferenceException(
        'Could not start the inference isolate: $error. The model factory '
        'must be a top-level function or a static method.',
      );
    }

    try {
      final info = await ready.future.timeout(loadTimeout);
      _commands = info.commands;
      _inputSpec = info.spec;
      _modelId = info.modelId;
      _state = _ServiceState.running;
    } on TimeoutException {
      _abortStart();
      throw InferenceException(
        'Model did not finish loading within ${loadTimeout.inSeconds} s',
      );
    } catch (_) {
      _abortStart();
      rethrow;
    }
  }

  void _abortStart() {
    _isolate?.kill(priority: Isolate.immediate);
    _releaseWorker();
    _state = _ServiceState.stopped;
  }

  void _onResult(_InferResult result) {
    _inFlight = false;
    _completedCount++;
    if (!_features.isClosed) _features.add(result.vector);
  }

  void _onFailure(_InferFailure failure) {
    _inFlight = false;
    _failedCount++;
    _emitError(
      InferenceException('Inference failed: ${failure.error}', failure.stack),
    );
  }

  void _onWorkerDied(InferenceException exception) {
    if (_state != _ServiceState.running) return;
    _emitError(exception);
    _isolate?.kill(priority: Isolate.immediate);
    _releaseWorker();
    _state = _ServiceState.stopped;
  }

  void _emitError(InferenceException exception) {
    developer.log(
      exception.message,
      name: 'ModelInferenceService',
      error: exception.details,
    );
    if (!_errors.isClosed) _errors.add(exception);
  }

  void _releaseWorker() {
    _replies?.close();
    _crashes?.close();
    _exits?.close();
    _replies = null;
    _crashes = null;
    _exits = null;
    _exitSignal = null;
    _isolate = null;
    _commands = null;
    _inputSpec = null;
    _modelId = null;
    _inFlight = false;
  }
}

// ---------------------------------------------------------------------------
// Messages between the UI isolate and the inference isolate. Every field is a
// sendable type (numbers, strings, typed data, ports, const specs).
// ---------------------------------------------------------------------------

class _WorkerInit {
  const _WorkerInit(this.replyTo, this.factory);

  final SendPort replyTo;
  final ModelModuleFactory factory;
}

class _WorkerReady {
  const _WorkerReady(this.commands, this.modelId, this.spec);

  final SendPort commands;
  final String modelId;
  final EegWindowSpec spec;
}

class _WorkerLoadFailed {
  const _WorkerLoadFailed(this.error, this.stack);

  final String error;
  final String stack;
}

class _InferRequest {
  const _InferRequest(this.id, this.windowEndSeconds, this.window);

  final int id;
  final double windowEndSeconds;
  final Float32List window;
}

class _InferResult {
  const _InferResult(this.id, this.vector);

  final int id;
  final FeatureVector vector;
}

class _InferFailure {
  const _InferFailure(this.id, this.error, this.stack);

  final int id;
  final String error;
  final String stack;
}

class _Shutdown {
  const _Shutdown();
}

// ---------------------------------------------------------------------------
// Inference isolate
// ---------------------------------------------------------------------------

Future<ModelModule?> _createAndLoad(_WorkerInit init) async {
  ModelModule? module;
  try {
    module = init.factory();
    await module.load();
    return module;
  } catch (error, stack) {
    try {
      module?.dispose();
    } catch (_) {
      // Best effort: the load already failed.
    }
    init.replyTo.send(_WorkerLoadFailed('$error', '$stack'));
    return null;
  }
}

Future<void> _inferenceWorkerMain(_WorkerInit init) async {
  final commands = ReceivePort();

  final module = await _createAndLoad(init);
  if (module == null) {
    commands.close();
    return;
  }

  init.replyTo.send(
    _WorkerReady(commands.sendPort, module.id, module.inputSpec),
  );

  await for (final message in commands) {
    if (message is _InferRequest) {
      final watch = Stopwatch()..start();
      try {
        final output = await module.infer(message.window);
        watch.stop();
        init.replyTo.send(
          _InferResult(
            message.id,
            output.copyWith(
              windowEndSeconds: message.windowEndSeconds,
              latencyMicros: watch.elapsedMicroseconds,
              modelId: module.id,
            ),
          ),
        );
      } catch (error, stack) {
        init.replyTo.send(_InferFailure(message.id, '$error', '$stack'));
      }
    } else if (message is _Shutdown) {
      commands.close();
      break;
    }
  }

  try {
    module.dispose();
  } catch (_) {
    // Nothing useful to do while shutting down.
  }
}
