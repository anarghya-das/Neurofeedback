import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'transport.dart';

// The Windows counterpart of the macOS RFCOMM plugin, written in Dart on top of
// Winsock (ws2_32.dll). It was checked on the lab's MW75 with
// tools/windows_rfcomm_probe.ps1: the command channel is found through the Serial
// Port service (SDP) and the raw EEG arrives on RFCOMM channel 25, about 31 kB/s.
//
// Blocking calls (connect, recv) run in isolates so the UI thread never waits on
// Bluetooth. Socket handles are process-wide, so the main isolate can still send
// and close what an isolate opened.

const _afBth = 32;
const _sockStream = 1;
const _bthprotoRfcomm = 3;
const _sdBoth = 2;

final DynamicLibrary _ws2 = DynamicLibrary.open('ws2_32.dll');

final int Function(int, Pointer<Uint8>) _wsaStartup = _ws2
    .lookupFunction<Int32 Function(Uint16, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('WSAStartup');
final int Function() _wsaGetLastError = _ws2.lookupFunction<Int32 Function(), int Function()>('WSAGetLastError');
final int Function(int, int, int) _wsSocket = _ws2
    .lookupFunction<IntPtr Function(Int32, Int32, Int32), int Function(int, int, int)>('socket');
final int Function(int, Pointer<Uint8>, int) _wsConnect = _ws2
    .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Int32), int Function(int, Pointer<Uint8>, int)>(
      'connect',
    );
final int Function(int, Pointer<Uint8>, int, int) _wsSend = _ws2
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Int32, Int32),
      int Function(int, Pointer<Uint8>, int, int)
    >('send');
final int Function(int, Pointer<Uint8>, int, int) _wsRecv = _ws2
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Int32, Int32),
      int Function(int, Pointer<Uint8>, int, int)
    >('recv');
final int Function(int, int) _wsShutdown = _ws2
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('shutdown');
final int Function(int) _wsClose = _ws2.lookupFunction<Int32 Function(IntPtr), int Function(int)>('closesocket');

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final int Function(Pointer<Int64>) _queryPerformanceCounter = _kernel32
    .lookupFunction<Int32 Function(Pointer<Int64>), int Function(Pointer<Int64>)>('QueryPerformanceCounter');
final int Function(Pointer<Int64>) _queryPerformanceFrequency = _kernel32
    .lookupFunction<Int32 Function(Pointer<Int64>), int Function(Pointer<Int64>)>('QueryPerformanceFrequency');
final Pointer<Int64> _counterOut = calloc<Int64>();
final double _counterFrequency = () {
  final out = calloc<Int64>();
  try {
    _queryPerformanceFrequency(out);
    return out.value == 0 ? 1.0 : out.value.toDouble();
  } finally {
    calloc.free(out);
  }
}();

/// Seconds on the Windows performance counter, the clock the received bytes are
/// stamped with. [Mw75Headset] compares it with LSL's clock and corrects for any
/// difference, so it does not have to be LSL's clock.
double _counterSeconds() {
  _queryPerformanceCounter(_counterOut);
  return _counterOut.value / _counterFrequency;
}

/// `50-0b-91-a9-39-84` or `50:0B:91:A9:39:84` as a 48-bit number, the form
/// Winsock wants.
int parseBluetoothAddress(String address) {
  final hex = address.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
  if (hex.length != 12) throw FormatException('Not a Bluetooth address: $address');
  return int.parse(hex, radix: 16);
}

/// The 30-byte `SOCKADDR_BTH` for a connection to [address].
///
/// With [service16] set and [port] 0, Windows looks the channel up through SDP
/// (the way the command channel is found); with [service16] 0 and a [port], it
/// connects to that RFCOMM channel directly (the data channel, 25).
Uint8List sockaddrBth(int address, {int service16 = 0, int port = 0}) {
  final data = ByteData(30);
  data.setUint16(0, _afBth, Endian.little);
  data.setUint64(2, address, Endian.little);
  if (service16 != 0) {
    // 0000xxxx-0000-1000-8000-00805F9B34FB, the Bluetooth base UUID.
    data.setUint32(10, service16, Endian.little);
    data.setUint16(14, 0, Endian.little);
    data.setUint16(16, 0x1000, Endian.little);
    const tail = [0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB];
    for (var i = 0; i < tail.length; i++) {
      data.setUint8(18 + i, tail[i]);
    }
  }
  data.setUint32(26, port, Endian.little);
  return data.buffer.asUint8List();
}

/// Parses the `name|instance id|status` lines the device query prints.
List<PairedDevice> parsePairedDevices(String output) {
  final devices = <PairedDevice>[];
  final id = RegExp(r'DEV_([0-9A-Fa-f]{12})');
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final parts = line.split('|');
    if (parts.length < 3) continue;
    final name = parts[0].trim();
    final match = id.firstMatch(parts[1]);
    if (name.isEmpty || match == null) continue;
    final hex = match.group(1)!.toLowerCase();
    final address = [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join('-');
    devices.add(PairedDevice(name: name, address: address, connected: parts[2].trim() == 'OK'));
  }
  return devices;
}

/// Runs in an isolate. Returns the connected socket, or the negative Winsock
/// error code.
int _connectBlocking(int address, int service16, int port) {
  final startup = calloc<Uint8>(1024);
  try {
    final r = _wsaStartup(0x0202, startup);
    if (r != 0) return -r;
  } finally {
    calloc.free(startup);
  }
  final socket = _wsSocket(_afBth, _sockStream, _bthprotoRfcomm);
  if (socket == -1) return -_nonZero(_wsaGetLastError());
  final name = calloc<Uint8>(30);
  try {
    name.asTypedList(30).setAll(0, sockaddrBth(address, service16: service16, port: port));
    if (_wsConnect(socket, name, 30) != 0) {
      final error = _nonZero(_wsaGetLastError());
      _wsClose(socket);
      return -error;
    }
  } finally {
    calloc.free(name);
  }
  return socket;
}

int _nonZero(int error) => error == 0 ? 1 : error;

/// Isolate entry point: `[socket, role (0 command, 1 data), SendPort]`. Sends
/// `[role, bytes, time]` for each read and `[role, null, 0.0, reason]` when the
/// link ends. The read blocks until data arrives or the main isolate closes the
/// socket; a receive timeout is avoided because Winsock leaves a socket in an
/// undefined state after one.
void _receiveLoop(List<Object> args) {
  final socket = args[0] as int;
  final role = args[1] as int;
  final port = args[2] as SendPort;
  const size = 16384;
  final buffer = calloc<Uint8>(size);
  var reason = 'closed by the headset';
  try {
    while (true) {
      final n = _wsRecv(socket, buffer, size, 0);
      if (n > 0) {
        port.send(<Object>[role, Uint8List.fromList(buffer.asTypedList(n)), _counterSeconds()]);
      } else {
        if (n < 0) reason = 'Windows Bluetooth error ${_wsaGetLastError()}';
        break;
      }
    }
  } finally {
    calloc.free(buffer);
  }
  port.send(<Object?>[role, null, 0.0, reason]);
}

/// RFCOMM over Winsock, with the same surface as the macOS plugin's channel.
class WindowsRfcomm {
  final _chunks = StreamController<RfcommChunk>.broadcast();
  final _closed = StreamController<RfcommRole>.broadcast();

  int _command = -1;
  int _data = -1;
  bool _closing = false;

  /// Why the last channel closed on its own, for the log and error text.
  String? closeReason;
  ReceivePort? _port;
  final _isolates = <Isolate>[];

  Stream<RfcommChunk> get chunks => _chunks.stream;
  Stream<RfcommRole> get closed => _closed.stream;

  /// Bluetooth devices Windows has paired, from the plug-and-play device list.
  Future<List<PairedDevice>> pairedDevices() async {
    const script =
        r"Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | "
        r"Where-Object { $_.InstanceId -like 'BTHENUM\DEV_*' } | "
        r"ForEach-Object { '{0}|{1}|{2}' -f $_.FriendlyName, $_.InstanceId, $_.Status }";
    final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script]);
    if (result.exitCode != 0) {
      throw PlatformException(
        code: 'device_list_failed',
        message: 'Could not list Bluetooth devices: ${result.stderr}'.trim(),
      );
    }
    return parsePairedDevices(result.stdout as String);
  }

  /// Opens the command channel (found by SDP lookup of [commandServiceUuid16]) and
  /// then the data channel [dataChannel], like the macOS plugin.
  Future<OpenChannels> open({
    required String address,
    required int dataChannel,
    required int commandServiceUuid16,
  }) async {
    await close();
    _closing = false;
    closeReason = null;
    final target = parseBluetoothAddress(address);

    final command = await Isolate.run(() => _connectBlocking(target, commandServiceUuid16, 0));
    if (command < 0) throw _connectError('command channel', -command);
    final data = await Isolate.run(() => _connectBlocking(target, 0, dataChannel));
    if (data < 0) {
      _wsClose(command);
      throw _connectError('data channel', -data);
    }
    _command = command;
    _data = data;

    final port = ReceivePort();
    _port = port;
    port.listen(_onMessage);
    _isolates.add(await Isolate.spawn(_receiveLoop, <Object>[command, 0, port.sendPort]));
    _isolates.add(await Isolate.spawn(_receiveLoop, <Object>[data, 1, port.sendPort]));
    return OpenChannels(commandChannel: -1, dataChannel: dataChannel);
  }

  Future<void> write(RfcommRole role, List<int> bytes) async {
    final socket = role == RfcommRole.data ? _data : _command;
    if (socket < 0) {
      final why = closeReason == null ? '' : ' ($closeReason)';
      throw PlatformException(code: 'not_open', message: 'The headset connection is not open$why.');
    }
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final sent = _wsSend(socket, buffer, bytes.length, 0);
      if (sent != bytes.length) {
        throw PlatformException(
          code: 'write_failed',
          message: 'Could not send to the headset (Windows Bluetooth error ${_wsaGetLastError()}).',
        );
      }
    } finally {
      calloc.free(buffer);
    }
  }

  Future<void> close() async {
    _closing = true;
    final command = _command;
    final data = _data;
    _command = -1;
    _data = -1;
    // shutdown first so a read blocked in another isolate returns at once.
    if (command >= 0) {
      _wsShutdown(command, _sdBoth);
      _wsClose(command);
    }
    if (data >= 0) {
      _wsShutdown(data, _sdBoth);
      _wsClose(data);
    }
    for (final isolate in _isolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    _isolates.clear();
    _port?.close();
    _port = null;
  }

  Future<double> hostClock() async => _counterSeconds();

  void _onMessage(Object? message) {
    if (message is! List) return;
    final role = message[0] == 1 ? RfcommRole.data : RfcommRole.command;
    final bytes = message[1];
    if (bytes is! Uint8List) {
      if (!_closing) {
        closeReason = message.length > 3 ? message[3] as String? : null;
        _closed.add(role);
      }
      return;
    }
    _chunks.add(
      RfcommChunk(role, bytes, Int32List.fromList([0]), Float64List.fromList([(message[2] as num).toDouble()])),
    );
  }

  static PlatformException _connectError(String what, int code) => PlatformException(
    code: 'connect_failed',
    message:
        'Could not open the $what (Windows Bluetooth error $code). Check that the headset is on, paired in '
        'Windows Settings and not in use by another app.',
  );
}
