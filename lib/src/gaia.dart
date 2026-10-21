import 'dart:typed_data';

/// Commands the MW75 Neuro accepts on its GAIA (serial-port) RFCOMM channel.
///
/// Frames are Qualcomm GAIA: `FF <version> <flags> <payload length>
/// <vendor:2> <command:2> <payload>`. Requests use version 4; the headset
/// replies with version 3 and the same vendor and command low byte, followed by
/// a 0xF1 status byte on success. Bytes match what Neurable Research Kit 1.1.3
/// sends and were checked against a headset running firmware 2.0.0.74.
class GaiaCommand {
  const GaiaCommand(this.name, this.bytes);

  final String name;
  final List<int> bytes;

  /// Vendor id (bytes 4–5) and command low byte (byte 7) identify the reply.
  int get vendor => bytes[4] << 8 | bytes[5];
  int get id => bytes[7];

  static GaiaCommand _mw75(String name, int id, int arg) =>
      GaiaCommand(name, [0xFF, 0x04, 0x00, 0x01, 0x09, 0x9A, 0x03, id, arg]);

  static final getConnectedDeviceCount = _mw75('get_connected_devices_count', 0x1E, 0xFF);
  static final getBatteryLevel = _mw75('get_battery_level', 0x14, 0xFF);
  static final getRawEegFeatureStatus = _mw75('get_raw_eeg_feature_status', 0x6B, 0xFF);
  static final getEegMode = _mw75('get_eeg_mode', 0x49, 0xFF);
  static final enableEeg = _mw75('enable_eeg', 0x60, 0x01);
  static final enableRawMode = _mw75('enable_raw_mode', 0x41, 0x01);
  static final disableRawMode = _mw75('disable_raw_mode', 0x41, 0x00);
  static final getClock = _mw75('get_clock', 0x32, 0xFF);
  static const getFirmwareVersion = GaiaCommand(
    'get_application_version',
    [0xFF, 0x04, 0x00, 0x00, 0x00, 0x1D, 0x00, 0x05],
  );

  /// Sets the headset clock: Unix seconds (u32 LE) and the local UTC offset in
  /// minutes (i16 LE).
  static GaiaCommand updateClock(DateTime now) {
    final payload = ByteData(6)
      ..setUint32(0, now.millisecondsSinceEpoch ~/ 1000, Endian.little)
      ..setInt16(4, now.timeZoneOffset.inMinutes, Endian.little);
    return GaiaCommand('update_clock', [
      0xFF, 0x04, 0x00, 0x06, 0x09, 0x9A, 0x03, 0x31,
      ...payload.buffer.asUint8List(),
    ]);
  }
}

/// One frame received from the headset.
class GaiaFrame {
  const GaiaFrame(this.bytes);

  final Uint8List bytes;

  int get vendor => bytes[4] << 8 | bytes[5];
  int get id => bytes[7];
  Uint8List get payload => Uint8List.sublistView(bytes, 8);

  /// 0xF1 marks success on the headset's MW75 (0x099A) commands.
  bool get acknowledged => bytes.length > 8 && bytes[8] == 0xF1;

  /// Byte 9: the value in most "get" replies (battery %, enabled flag, ...).
  int? get value => bytes.length > 9 ? bytes[9] : null;

  bool answers(GaiaCommand command) => vendor == command.vendor && id == command.id;

  /// The headset's own contact level per ear cup, 0–5 (left, right), from its
  /// unsolicited `09 9A 03 E1 <left> <right>` message; null for other frames.
  /// The same levels drive Research Kit's metrics-mode contact display.
  (int, int)? get cupContact => vendor == 0x099A && id == 0xE1 && bytes.length >= 10 ? (bytes[8], bytes[9]) : null;

  String get hex => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

/// Reassembles GAIA frames from the command channel. Replies can arrive split
/// across RFCOMM callbacks or several to a callback, interleaved with
/// unsolicited notifications.
class GaiaFrameParser {
  final _buffer = <int>[];

  List<GaiaFrame> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final frames = <GaiaFrame>[];
    while (true) {
      final start = _buffer.indexOf(0xFF);
      if (start < 0) {
        _buffer.clear();
        break;
      }
      if (start > 0) _buffer.removeRange(0, start);
      if (_buffer.length < 8) break;
      final hasChecksum = _buffer[2] & 0x01 != 0;
      final length = 8 + _buffer[3] + (hasChecksum ? 1 : 0);
      if (_buffer.length < length) break;
      frames.add(GaiaFrame(Uint8List.fromList(_buffer.sublist(0, length))));
      _buffer.removeRange(0, length);
    }
    return frames;
  }

  void reset() => _buffer.clear();
}
