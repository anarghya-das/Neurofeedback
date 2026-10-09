import 'package:flutter/services.dart';

/// An audio output on this Mac.
class AudioOutputDevice {
  const AudioOutputDevice({required this.id, required this.name, required this.isDefault, required this.bluetooth});

  /// Core Audio device id; valid until the device is unplugged or disconnected.
  final int id;
  final String name;

  /// The current system output.
  final bool isDefault;
  final bool bluetooth;
}

/// The output the tones are playing on, once started.
class ToneOutputInfo {
  const ToneOutputInfo({
    required this.device,
    required this.bluetooth,
    required this.sampleRate,
    required this.latency,
  });

  final String device;
  final bool bluetooth;
  final double sampleRate;

  /// Seconds from a tone leaving the app to it being heard, as macOS reports it
  /// for the device. Already included in the onsets [ToneOutput.play] returns.
  final double latency;
}

/// Plays tones whose onsets are known on LSL's clock (see ToneStimulator.swift).
class ToneOutput {
  static const _methods = MethodChannel('mw75_neuro');

  Future<List<AudioOutputDevice>> devices() async {
    final raw = await _methods.invokeListMethod<Map<Object?, Object?>>('audioOutputs') ?? [];
    return [
      for (final m in raw)
        AudioOutputDevice(
          id: m['id'] as int,
          name: m['name'] as String? ?? '',
          isDefault: m['isDefault'] as bool? ?? false,
          bluetooth: m['bluetooth'] as bool? ?? false,
        ),
    ];
  }

  /// Starts the audio engine on [deviceId], or the system output when null.
  /// It plays silence between tones until [stop].
  Future<ToneOutputInfo> start({int? deviceId}) async {
    final r = await _methods.invokeMapMethod<String, Object?>('audioStart', {'deviceId': deviceId});
    return ToneOutputInfo(
      device: r?['device'] as String? ?? '',
      bluetooth: r?['bluetooth'] as bool? ?? false,
      sampleRate: (r?['sampleRate'] as num?)?.toDouble() ?? 0,
      latency: (r?['latency'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Schedules a tone to be heard at [at] (LSL clock seconds), or as soon as
  /// possible when null or too soon, and returns when it will be heard.
  Future<double> play({
    required double frequency,
    required double duration,
    required double amplitude,
    double? at,
  }) async {
    final onset = await _methods.invokeMethod<double>('audioPlay', {
      'frequency': frequency,
      'duration': duration,
      'amplitude': amplitude,
      'at': at,
    });
    return onset!;
  }

  Future<void> stop() => _methods.invokeMethod<void>('audioStop');

  /// Speaks [text] on the system output, interrupting anything still being
  /// said; null just stops speaking.
  Future<void> speak(String? text) => _methods.invokeMethod<void>('speak', {'text': text});
}
