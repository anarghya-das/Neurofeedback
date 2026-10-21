import 'dart:typed_data';

/// Wire-level constants of the Neurable MW75 Neuro, as used by Neurable
/// Research Kit 1.1.3. See docs/neurable-mw75-protocol.md for how they were
/// derived.
abstract final class Mw75Protocol {
  /// RFCOMM channel the headset streams raw EEG on.
  static const int dataRfcommChannel = 25;

  /// Commands go to the channel advertising the Serial Port service.
  static const int commandServiceUuid16 = 0x1101;

  static const int dataSync = 0xAA;
  static const int eegEventId = 0xEF;
  static const int dataLength = 60;
  static const int packetSize = 63;
  static const int commandSync = 0xF6;

  static const int eegChannelCount = 12;
  static const double samplingRate = 500;

  /// Raw 24-bit ADC count → µV (200000 / 2^23), the same float32 factor
  /// Research Kit uses.
  static const double rawToMicrovolts = 0.023841858;
}

/// One decoded 63-byte EEG packet.
class Mw75Packet {
  Mw75Packet({
    required this.counter,
    required this.ref,
    required this.drl,
    required this.rawChannels,
    required this.featureStatus,
    required this.hostTime,
  });

  /// Hardware counter, wraps at 255.
  final int counter;

  /// Reference and driven-right-leg electrode values (12-bit, unscaled).
  final double ref;
  final double drl;

  /// Raw ADC counts for Ch1..Ch12.
  final Float32List rawChannels;
  final int featureStatus;

  /// Arrival time of the packet's last byte, in LSL clock seconds.
  final double hostTime;

  double microvolts(int channel) => rawChannels[channel] * Mw75Protocol.rawToMicrovolts;
}

/// Splits the raw RFCOMM byte stream into [Mw75Packet]s.
///
/// Validates sync byte, event id, length byte and checksum; on any mismatch it
/// drops a single byte and searches for the next sync byte.
class Mw75PacketParser {
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  /// Bytes discarded while resynchronising, for diagnostics.
  int droppedBytes = 0;

  /// Packets rejected because the checksum did not match.
  int checksumErrors = 0;

  /// Feeds [bytes] that arrived at [time] and returns every complete packet.
  List<Mw75Packet> add(Uint8List bytes, double time) {
    _buffer
      ..add(_pending)
      ..add(bytes);
    final data = _buffer.takeBytes();
    final view = ByteData.sublistView(data);
    final packets = <Mw75Packet>[];

    var i = 0;
    while (data.length - i >= Mw75Protocol.packetSize) {
      if (data[i] != Mw75Protocol.dataSync ||
          data[i + 1] != Mw75Protocol.eegEventId ||
          data[i + 2] != Mw75Protocol.dataLength) {
        i++;
        droppedBytes++;
        continue;
      }
      if (!_checksumOk(data, i, view)) {
        checksumErrors++;
        i++;
        droppedBytes++;
        continue;
      }
      packets.add(_decode(view, i, time));
      i += Mw75Protocol.packetSize;
    }

    _pending = Uint8List.sublistView(data, i);
    return packets;
  }

  void reset() {
    _buffer.clear();
    _pending = Uint8List(0);
  }

  static bool _checksumOk(Uint8List data, int start, ByteData view) {
    var sum = 0;
    for (var k = 0; k <= Mw75Protocol.dataLength; k++) {
      sum += data[start + k];
    }
    final expected = view.getUint16(start + Mw75Protocol.dataLength + 1, Endian.little);
    return (sum & 0xFFFF) == expected;
  }

  static Mw75Packet _decode(ByteData view, int start, double time) {
    final channels = Float32List(Mw75Protocol.eegChannelCount);
    for (var c = 0; c < channels.length; c++) {
      channels[c] = view.getFloat32(start + 12 + 4 * c, Endian.little);
    }
    return Mw75Packet(
      counter: view.getUint8(start + 3),
      ref: view.getFloat32(start + 4, Endian.little),
      drl: view.getFloat32(start + 8, Endian.little),
      rawChannels: channels,
      featureStatus: view.getUint8(start + Mw75Protocol.dataLength),
      hostTime: time,
    );
  }

  /// Builds a valid packet; used by tests and the simulator.
  static Uint8List encode({
    required int counter,
    required double ref,
    required double drl,
    required List<double> rawChannels,
    int featureStatus = 0,
  }) {
    final bytes = Uint8List(Mw75Protocol.packetSize);
    final view = ByteData.sublistView(bytes);
    bytes[0] = Mw75Protocol.dataSync;
    bytes[1] = Mw75Protocol.eegEventId;
    bytes[2] = Mw75Protocol.dataLength;
    bytes[3] = counter & 0xFF;
    view.setFloat32(4, ref, Endian.little);
    view.setFloat32(8, drl, Endian.little);
    for (var c = 0; c < Mw75Protocol.eegChannelCount; c++) {
      view.setFloat32(12 + 4 * c, rawChannels[c], Endian.little);
    }
    bytes[Mw75Protocol.dataLength] = featureStatus;
    var sum = 0;
    for (var k = 0; k <= Mw75Protocol.dataLength; k++) {
      sum += bytes[k];
    }
    view.setUint16(Mw75Protocol.dataLength + 1, sum & 0xFFFF, Endian.little);
    return bytes;
  }
}

/// Electrode pairs on the ear cups, 0-based channel indices.
///
/// Positions come from the ear-cup diagram Research Kit draws (eight sensors
/// 45° apart, clockwise from the top: left cup Ch2, Ch3, Ch4, Ref, Ch5, Ref,
/// Ch6, Ch1; right cup Ch7, Ch12, DRL, Ch11, DRL, Ch10, Ch9, Ch8). Each pair
/// is a top electrode and the one diametrically opposite it at the bottom:
/// the vertical, widest-spaced kind of pair that around-the-ear EEG studies
/// (cEEGrid) find carries the P300 best.
abstract final class Mw75Montage {
  /// Sensors on each cushion as Research Kit draws them: eight positions 45°
  /// apart, clockwise from just right of the top. Digits are channel numbers
  /// (1-based), R the reference and D the driven right leg.
  static const leftCup = ['2', '3', '4', 'R', '5', 'R', '6', '1'];
  static const rightCup = ['7', '12', 'D', '11', 'D', '10', '9', '8'];

  /// Ch2 (top) minus Ch5 (bottom).
  static const leftTop = 1, leftBottom = 4;

  /// Ch8 (top) minus Ch11 (bottom).
  static const rightTop = 7, rightBottom = 10;
}
