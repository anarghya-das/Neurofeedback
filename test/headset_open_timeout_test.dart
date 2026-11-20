import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// A transport whose open never answers, like picking AirPods instead of the
/// MW75 in the Mac test.
class _SilentTransport implements Mw75Transport {
  int closes = 0;

  @override
  Stream<RfcommChunk> get chunks => const Stream.empty();
  @override
  Stream<RfcommRole> get closed => const Stream.empty();
  @override
  String? get closeReason => null;
  @override
  Future<OpenChannels> open({required String address, required int dataChannel, required int commandServiceUuid16}) =>
      Completer<OpenChannels>().future;
  @override
  Future<void> close() async => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a device that never answers ends in an error instead of starting forever', () async {
    final transport = _SilentTransport();
    final headset = Mw75Headset(transport: transport, openTimeout: const Duration(milliseconds: 50))
      ..publishToLsl = false
      ..selectDevice(const PairedDevice(name: "Chaeyeon's AirPods Pro", address: '00-11-22-33-44-55', connected: true));
    addTearDown(headset.dispose);

    await headset.start().timeout(const Duration(seconds: 5));

    expect(headset.state, HeadsetState.error);
    expect(headset.statusText, contains('''Could not connect to "Chaeyeon's AirPods Pro"'''));
    expect(headset.statusText, contains('MW75'));
    expect(transport.closes, greaterThan(0), reason: 'the half-done open is cancelled');
  });
}
