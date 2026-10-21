import 'dart:async';
import 'dart:typed_data';

import 'package:eeg_viewer_lsl/models/eeg_window.dart';
import 'package:eeg_viewer_lsl/models/feature_vector.dart';
import 'package:eeg_viewer_lsl/services/dummy_model_module.dart';
import 'package:eeg_viewer_lsl/services/model_inference_service.dart';
import 'package:eeg_viewer_lsl/services/model_module.dart';
import 'package:flutter_test/flutter_test.dart';

const _spec = EegWindowSpec(
  channelCount: 2,
  samplesPerChannel: 64,
  samplingRate: 64,
);

const _timeout = Duration(seconds: 10);

// Factories must be top-level functions so they can be sent to the isolate.
ModelModule _fastModel() => DummyModelModule(spec: _spec);

ModelModule _slowModel() => DummyModelModule(
  spec: _spec,
  busyWork: const Duration(milliseconds: 250),
);

ModelModule _loadFailsModel() => _ScriptedModule(failOnLoad: true);

ModelModule _inferFailsModel() => _ScriptedModule(failOnInfer: true);

class _ScriptedModule implements ModelModule {
  _ScriptedModule({this.failOnLoad = false, this.failOnInfer = false});

  final bool failOnLoad;
  final bool failOnInfer;

  @override
  String get id => 'scripted';

  @override
  EegWindowSpec get inputSpec => _spec;

  @override
  Future<void> load() async {
    if (failOnLoad) throw StateError('cannot load weights');
  }

  @override
  FeatureVector infer(Float32List window) {
    if (failOnInfer) throw StateError('boom');
    return FeatureVector(values: Float32List.fromList(<double>[1.0]));
  }

  @override
  void dispose() {}
}

Float32List _window() {
  final data = Float32List(_spec.length);
  for (var i = 0; i < data.length; i++) {
    data[i] = (i.isEven ? 1.0 : -1.0) * 20;
  }
  return data;
}

void main() {
  test('runs a window through the model and publishes the features', () async {
    final service = ModelInferenceService(factory: _fastModel);
    addTearDown(service.dispose);

    await service.start();
    expect(service.isRunning, isTrue);
    expect(service.modelId, 'dummy');
    expect(service.inputSpec, _spec);

    final next = service.features.first;
    expect(service.submit(_window(), windowEndSeconds: 12.5), isTrue);
    final features = await next.timeout(_timeout);

    expect(features.modelId, 'dummy');
    expect(features.windowEndSeconds, 12.5);
    expect(features.labels, DummyModelModule.featureLabels);
    expect(features.latencyMicros, greaterThanOrEqualTo(0));
    expect(service.completedCount, 1);
    expect(service.isBusy, isFalse);
  });

  test('refuses windows before start and after stop', () async {
    final service = ModelInferenceService(factory: _fastModel);
    addTearDown(service.dispose);

    expect(service.submit(_window()), isFalse);

    await service.start();
    await service.stop();

    expect(service.isRunning, isFalse);
    expect(service.submit(_window()), isFalse);
  });

  test('throws when the window has the wrong size', () async {
    final service = ModelInferenceService(factory: _fastModel);
    addTearDown(service.dispose);
    await service.start();

    expect(() => service.submit(Float32List(3)), throwsArgumentError);
  });

  test('drops a window while the model is busy, then recovers', () async {
    final service = ModelInferenceService(factory: _slowModel);
    addTearDown(service.dispose);
    await service.start();

    final first = service.features.first;
    expect(service.submit(_window()), isTrue);
    expect(service.isBusy, isTrue);
    expect(service.submit(_window()), isFalse);
    expect(service.droppedCount, 1);

    await first.timeout(_timeout);
    expect(service.isBusy, isFalse);

    final second = service.features.first;
    expect(service.submit(_window()), isTrue);
    await second.timeout(_timeout);
    expect(service.completedCount, 2);
  });

  test('a slow model does not block the calling isolate', () async {
    final service = ModelInferenceService(factory: _slowModel);
    addTearDown(service.dispose);
    await service.start();

    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    addTearDown(timer.cancel);

    final next = service.features.first;
    service.submit(_window());
    final features = await next.timeout(_timeout);
    timer.cancel();

    // The model spent 250 ms working. If that had happened on this isolate the
    // timer could not have fired (about 25 ticks are expected).
    expect(features.latencyMicros, greaterThanOrEqualTo(250000));
    expect(ticks, greaterThan(5));
  });

  test('start fails with an InferenceException when loading fails', () async {
    final service = ModelInferenceService(factory: _loadFailsModel);
    addTearDown(service.dispose);

    await expectLater(
      service.start(),
      throwsA(
        isA<InferenceException>().having(
          (e) => e.message,
          'message',
          contains('cannot load weights'),
        ),
      ),
    );

    expect(service.isRunning, isFalse);
    expect(service.submit(_window()), isFalse);
  });

  test('a failing window is reported and the service keeps running', () async {
    final service = ModelInferenceService(factory: _inferFailsModel);
    addTearDown(service.dispose);
    await service.start();

    final error = service.errors.first;
    expect(service.submit(_window()), isTrue);
    final exception = await error.timeout(_timeout);

    expect(exception.message, contains('boom'));
    expect(service.failedCount, 1);
    expect(service.isRunning, isTrue);
    expect(service.isBusy, isFalse);
  });

  test('can be restarted after stop', () async {
    final service = ModelInferenceService(factory: _fastModel);
    addTearDown(service.dispose);

    await service.start();
    await service.stop();
    await service.start();

    final next = service.features.first;
    expect(service.submit(_window()), isTrue);
    await next.timeout(_timeout);
    expect(service.completedCount, 1);
  });

  test('concurrent start calls share one startup', () async {
    final service = ModelInferenceService(factory: _fastModel);
    addTearDown(service.dispose);

    await Future.wait([service.start(), service.start()]);

    expect(service.isRunning, isTrue);
  });

  test('cannot be started after dispose', () async {
    final service = ModelInferenceService(factory: _fastModel);
    await service.start();
    await service.dispose();

    await expectLater(service.start(), throwsStateError);
  });
}
