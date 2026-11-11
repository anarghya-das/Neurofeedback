import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'windows_rfcomm.dart';

/// A Bluetooth device paired with this computer.
class PairedDevice {
  const PairedDevice({
    required this.name,
    required this.address,
    required this.connected,
  });

  final String name;

  /// Bluetooth address as macOS reports it, e.g. `"aa-bb-cc-dd-ee-ff"`.
  final String address;

  /// Whether macOS currently has a baseband connection to the device.
  final bool connected;

  @override
  String toString() => 'PairedDevice($name, $address, connected: $connected)';
}

/// Which of the two RFCOMM channels a chunk of bytes belongs to.
enum RfcommRole { command, data }

/// Bytes received on one channel, coalesced by the native side.
///
/// [segmentOffsets] and [segmentTimes] describe the individual RFCOMM callbacks
/// that make up [bytes]: segment `i` starts at `bytes[segmentOffsets[i]]` and
/// arrived at `segmentTimes[i]`, in seconds on the same clock as LSL's
/// `lsl_local_clock()`.
class RfcommChunk {
  const RfcommChunk(this.role, this.bytes, this.segmentOffsets, this.segmentTimes);

  final RfcommRole role;
  final Uint8List bytes;
  final Int32List segmentOffsets;
  final Float64List segmentTimes;
}

/// The result of opening both channels.
/// One notification from a BLE characteristic.
class BleNotification {
  const BleNotification(this.characteristic, this.bytes, this.time);

  /// Characteristic UUID, upper case.
  final String characteristic;
  final Uint8List bytes;

  /// Arrival time in LSL clock seconds.
  final double time;
}

/// The headset's BLE GATT link once connected.
class BleConnection {
  const BleConnection({required this.name, required this.identifier, required this.characteristics});

  final String name;

  /// macOS's identifier for the peripheral (not the Bluetooth address).
  final String identifier;

  /// Every characteristic found, with whether it is now notifying.
  final Map<String, bool> characteristics;
}

/// Events from the BLE link that are not data.
class _BleDisconnected {
  const _BleDisconnected();
}

class _BleLog {
  const _BleLog(this.message);

  final String message;
}

class OpenChannels {
  const OpenChannels({required this.commandChannel, required this.dataChannel});

  final int commandChannel;
  final int dataChannel;
}

/// Thin wrapper around the native RFCOMM plugin. It only moves bytes; the MW75
/// protocol is implemented on top of it in [Mw75Headset].
///
/// There is one instance per app: the native side has a single event sink and
/// Flutter a single handler per channel, so two transports would silently cut
/// each other off. The raw-EEG and metrics sessions share it.
class Mw75Transport {
  factory Mw75Transport() => _instance;

  Mw75Transport._()
      : _methods = const MethodChannel('mw75_neuro'),
        _events = const EventChannel('mw75_neuro/events'),
        _windows = Platform.isWindows ? WindowsRfcomm() : null;

  static final _instance = Mw75Transport._();

  final MethodChannel _methods;
  final EventChannel _events;

  /// On Windows the RFCOMM channels are opened from Dart (Winsock) instead of
  /// through the native plugin macOS uses. BLE is macOS only.
  final WindowsRfcomm? _windows;

  late final Stream<Object> _eventStream = _events
      .receiveBroadcastStream()
      .map(_decodeEvent)
      .where((e) => e != null)
      .cast<Object>();

  /// Received bytes. Subscribe before calling [open] so nothing is dropped.
  Stream<RfcommChunk> get chunks => _windows?.chunks ?? _eventStream.where((e) => e is RfcommChunk).cast();

  /// Emits the role of a channel when the headset or macOS closes it.
  Stream<RfcommRole> get closed => _windows?.closed ?? _eventStream.where((e) => e is RfcommRole).cast();

  /// Why a channel last closed on its own, when the platform says (Windows).
  String? get closeReason => _windows?.closeReason;

  /// Notifications from subscribed BLE characteristics.
  Stream<BleNotification> get bleNotifications => _eventStream.where((e) => e is BleNotification).cast();

  /// Fires when the headset drops an established BLE link.
  Stream<void> get bleDisconnected => _eventStream.where((e) => e is _BleDisconnected).map((_) {});

  /// Non-fatal BLE problems worth logging (a failed subscribe or write).
  Stream<String> get bleLogs => _eventStream.where((e) => e is _BleLog).map((e) => (e as _BleLog).message);

  Future<List<PairedDevice>> pairedDevices() async {
    final windows = _windows;
    if (windows != null) return windows.pairedDevices();
    final raw = await _methods.invokeListMethod<Map<Object?, Object?>>('pairedDevices') ?? [];
    return raw
        .map(
          (m) => PairedDevice(
            name: m['name'] as String? ?? '',
            address: m['address'] as String? ?? '',
            connected: m['connected'] as bool? ?? false,
          ),
        )
        .toList();
  }

  /// Opens the command channel (located by SDP lookup of [commandServiceUuid16])
  /// and then the data channel [dataChannel].
  Future<OpenChannels> open({
    required String address,
    required int dataChannel,
    required int commandServiceUuid16,
  }) async {
    final windows = _windows;
    if (windows != null) {
      return windows.open(
        address: address,
        dataChannel: dataChannel,
        commandServiceUuid16: commandServiceUuid16,
      );
    }
    final result = await _methods.invokeMapMethod<String, Object?>('open', {
      'address': address,
      'dataChannel': dataChannel,
      'commandServiceUuid16': commandServiceUuid16,
    });
    return OpenChannels(
      commandChannel: result?['commandChannel'] as int? ?? -1,
      dataChannel: result?['dataChannel'] as int? ?? -1,
    );
  }

  Future<void> write(RfcommRole role, List<int> bytes) async {
    final windows = _windows;
    if (windows != null) return windows.write(role, bytes);
    await _methods.invokeMethod<bool>('write', {
      'channel': role.name,
      'bytes': Uint8List.fromList(bytes),
    });
  }

  Future<void> close() => _windows?.close() ?? _methods.invokeMethod<void>('close');

  /// The native clock used for [RfcommChunk.segmentTimes], for diagnostics.
  Future<double> hostClock() async => _windows != null
      ? await _windows.hostClock()
      : await _methods.invokeMethod<double>('clock') ?? 0;

  /// Finds a peripheral whose name contains [nameContains] (one already connected
  /// to this Mac first, otherwise by scanning), connects, and subscribes to
  /// [notify].
  Future<BleConnection> bleConnect({
    required String service,
    required List<String> notify,
    String nameContains = 'MW75',
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final r = await _methods.invokeMapMethod<String, Object?>('bleConnect', {
      'service': service,
      'notify': notify,
      'nameContains': nameContains,
      'timeoutSeconds': timeout.inMilliseconds / 1000,
    });
    final chars = <String, bool>{
      for (final c in (r?['characteristics'] as List? ?? const []).cast<Map<Object?, Object?>>())
        c['uuid'] as String: c['notifying'] as bool? ?? false,
    };
    return BleConnection(
      name: r?['name'] as String? ?? '',
      identifier: r?['identifier'] as String? ?? '',
      characteristics: chars,
    );
  }

  Future<void> bleWrite(String characteristic, List<int> bytes, {bool withResponse = true}) async {
    await _methods.invokeMethod<bool>('bleWrite', {
      'characteristic': characteristic,
      'bytes': Uint8List.fromList(bytes),
      'withResponse': withResponse,
    });
  }

  Future<void> bleDisconnect() => _methods.invokeMethod<void>('bleDisconnect');

  static Object? _decodeEvent(Object? event) {
    if (event is! Map) return null;
    final role = event['channel'] == 'data' ? RfcommRole.data : RfcommRole.command;
    switch (event['event']) {
      case 'ble':
        return BleNotification(
          event['characteristic'] as String,
          event['bytes'] as Uint8List,
          (event['time'] as num).toDouble(),
        );
      case 'bleDisconnected':
        return const _BleDisconnected();
      case 'bleLog':
        return _BleLog(event['message'] as String? ?? '');
      case 'data':
        return RfcommChunk(
          role,
          event['bytes'] as Uint8List,
          event['offsets'] as Int32List,
          event['times'] as Float64List,
        );
      case 'closed':
        return role;
    }
    return null;
  }
}
