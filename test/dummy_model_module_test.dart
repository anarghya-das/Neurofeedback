import 'dart:typed_data';

import 'package:eeg_viewer_lsl/models/eeg_window.dart';
import 'package:eeg_viewer_lsl/services/dummy_model_module.dart';
import 'package:flutter_test/flutter_test.dart';

const _spec = EegWindowSpec(
  channelCount: 2,
  samplesPerChannel: 8,
  samplingRate: 8,
);

/// Window where sample `i` of channel `c` is `f(c, i)`.
Float32List _window(double Function(int channel, int index) f) {
  final data = Float32List(_spec.length);
  for (var c = 0; c < _spec.channelCount; c++) {
    for (var i = 0; i < _spec.samplesPerChannel; i++) {
      data[c * _spec.samplesPerChannel + i] = f(c, i);
    }
  }
  return data;
}

/// Zero-mean square wave with the given amplitude.
double _wave(double amplitude, int index) =>
    index.isEven ? amplitude : -amplitude;

void main() {
  test('defaults to 8 channels x 512 samples at 256 Hz', () {
    expect(
      DummyModelModule().inputSpec,
      const EegWindowSpec(
        channelCount: 8,
        samplesPerChannel: 512,
        samplingRate: 256,
      ),
    );
    expect(createDummyModelModule().id, 'dummy');
  });

  test('returns three labelled features in the 0..1 range', () {
    final module = DummyModelModule(spec: _spec);
    final features = module.infer(_window((c, i) => _wave(30.0 + c, i)));

    expect(features.length, 3);
    expect(features.labels, ['energy', 'roughness', 'balance']);
    for (var i = 0; i < features.length; i++) {
      expect(features[i], inInclusiveRange(0.0, 1.0));
    }
    expect(features.valueOf('energy'), features[0]);
    expect(features.valueOf('missing'), isNull);
  });

  test('a flat signal has no energy, no roughness, and balanced power', () {
    final module = DummyModelModule(spec: _spec);
    // A constant offset must be removed, so 7.0 behaves like silence.
    final features = module.infer(_window((c, i) => 7.0));

    expect(features.valueOf('energy'), 0.0);
    expect(features.valueOf('roughness'), 0.0);
    expect(features.valueOf('balance'), 0.5);
  });

  test('louder input gives a higher energy value', () {
    final module = DummyModelModule(spec: _spec);
    final quiet = module.infer(_window((c, i) => _wave(10, i)));
    final loud = module.infer(_window((c, i) => _wave(100, i)));

    expect(loud.valueOf('energy')!, greaterThan(quiet.valueOf('energy')!));
    expect(
      loud.valueOf('roughness')!,
      greaterThan(quiet.valueOf('roughness')!),
    );
  });

  test('balance follows which half of the channels carries the power', () {
    final module = DummyModelModule(spec: _spec);
    final firstHalf = module.infer(
      _window((c, i) => c == 0 ? _wave(50, i) : 0.0),
    );
    final secondHalf = module.infer(
      _window((c, i) => c == 1 ? _wave(50, i) : 0.0),
    );

    expect(firstHalf.valueOf('balance'), 1.0);
    expect(secondHalf.valueOf('balance'), 0.0);
  });

  test('is deterministic', () {
    final module = DummyModelModule(spec: _spec);
    final data = _window((c, i) => (c + 1) * (i * 1.5 - 4));

    expect(module.infer(data).values, equals(module.infer(data).values));
  });

  test('rejects a window of the wrong size', () {
    final module = DummyModelModule(spec: _spec);

    expect(() => module.infer(Float32List(3)), throwsArgumentError);
  });

  test('busyWork makes infer take at least that long', () {
    final module = DummyModelModule(
      spec: _spec,
      busyWork: const Duration(milliseconds: 30),
    );
    final watch = Stopwatch()..start();
    module.infer(Float32List(_spec.length));

    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(30));
  });
}
