import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:lsl_bindings/lsl_bindings.dart';

/// Description of one channel in the stream's `desc/channels` metadata.
class LslChannel {
  const LslChannel(this.label, {required this.unit, required this.type});

  final String label;
  final String unit;
  final String type;
}

/// A float32 LSL outlet with channel metadata.
///
/// `lsl_flutter`'s StreamInfo cannot carry a `desc` element, so recorders such as
/// LabRecorder would see unlabeled channels. This talks to liblsl directly
/// through `lsl_bindings` (the same library `lsl_flutter` loads).
class LslEegOutlet {
  LslEegOutlet._(this._outlet, this.channelCount);

  final lsl_outlet _outlet;
  final int channelCount;
  bool _closed = false;

  Pointer<Float> _samples = nullptr;
  Pointer<Double> _timestamps = nullptr;
  int _capacity = 0;

  static LslBindings get _lsl => lslBindings;

  /// The LSL clock, the same clock the native transport timestamps with.
  static double localClock() => _lsl.lsl_local_clock();

  static LslEegOutlet create({
    required String name,
    required String type,
    required String sourceId,
    required double nominalRate,
    required List<LslChannel> channels,
    Map<String, String> extraDesc = const {},
  }) {
    return using((arena) {
      final info = _lsl.lsl_create_streaminfo(
        name.toNativeUtf8(allocator: arena).cast(),
        type.toNativeUtf8(allocator: arena).cast(),
        channels.length,
        nominalRate,
        lsl_channel_format_t.cft_float32,
        sourceId.toNativeUtf8(allocator: arena).cast(),
      );
      Pointer<Char> s(String v) => v.toNativeUtf8(allocator: arena).cast();

      final desc = _lsl.lsl_get_desc(info);
      for (final entry in extraDesc.entries) {
        _lsl.lsl_append_child_value(desc, s(entry.key), s(entry.value));
      }
      final channelsNode = _lsl.lsl_append_child(desc, s('channels'));
      for (final channel in channels) {
        final node = _lsl.lsl_append_child(channelsNode, s('channel'));
        _lsl.lsl_append_child_value(node, s('label'), s(channel.label));
        _lsl.lsl_append_child_value(node, s('unit'), s(channel.unit));
        _lsl.lsl_append_child_value(node, s('type'), s(channel.type));
      }

      // chunk_size 0: each push is sent as one chunk; buffer up to 6 minutes.
      final outlet = _lsl.lsl_create_outlet(info, 0, 360);
      _lsl.lsl_destroy_streaminfo(info);
      if (outlet == nullptr) {
        throw StateError('liblsl could not create outlet "$name"');
      }
      return LslEegOutlet._(outlet, channels.length);
    });
  }

  /// Pushes [samples] (each of length [channelCount]) with one timestamp each.
  void pushChunk(List<List<double>> samples, List<double> timestamps) {
    if (_closed || samples.isEmpty) return;
    _ensureCapacity(samples.length);
    for (var i = 0; i < samples.length; i++) {
      final row = samples[i];
      for (var c = 0; c < channelCount; c++) {
        _samples[i * channelCount + c] = row[c];
      }
      _timestamps[i] = timestamps[i];
    }
    _lsl.lsl_push_chunk_ftnp(_outlet, _samples, samples.length * channelCount, _timestamps, 1);
  }

  bool get hasConsumers => !_closed && _lsl.lsl_have_consumers(_outlet) > 0;

  void close() {
    if (_closed) return;
    _closed = true;
    _lsl.lsl_destroy_outlet(_outlet);
    if (_capacity > 0) {
      malloc.free(_samples);
      malloc.free(_timestamps);
    }
    _capacity = 0;
  }

  void _ensureCapacity(int rows) {
    if (rows <= _capacity) return;
    if (_capacity > 0) {
      malloc.free(_samples);
      malloc.free(_timestamps);
    }
    _capacity = rows * 2;
    _samples = malloc<Float>(_capacity * channelCount);
    _timestamps = malloc<Double>(_capacity);
  }
}

/// An irregular-rate string outlet for event markers, which LabRecorder records
/// next to the EEG.
class LslMarkerOutlet {
  LslMarkerOutlet._(this._outlet);

  final lsl_outlet _outlet;
  bool _closed = false;

  static LslMarkerOutlet create({
    required String name,
    required String sourceId,
    Map<String, String> extraDesc = const {},
  }) {
    return using((arena) {
      Pointer<Char> s(String v) => v.toNativeUtf8(allocator: arena).cast();
      final info = lslBindings.lsl_create_streaminfo(
        s(name),
        s('Markers'),
        1,
        0, // irregular rate
        lsl_channel_format_t.cft_string,
        s(sourceId),
      );
      final desc = lslBindings.lsl_get_desc(info);
      for (final entry in extraDesc.entries) {
        lslBindings.lsl_append_child_value(desc, s(entry.key), s(entry.value));
      }
      final outlet = lslBindings.lsl_create_outlet(info, 0, 360);
      lslBindings.lsl_destroy_streaminfo(info);
      if (outlet == nullptr) {
        throw StateError('liblsl could not create outlet "$name"');
      }
      return LslMarkerOutlet._(outlet);
    });
  }

  void push(String marker, double timestamp) {
    if (_closed) return;
    using((arena) {
      final sample = arena<Pointer<Char>>();
      sample.value = marker.toNativeUtf8(allocator: arena).cast();
      lslBindings.lsl_push_sample_strt(_outlet, sample, timestamp);
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    lslBindings.lsl_destroy_outlet(_outlet);
  }
}
