import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/src/windows_rfcomm.dart';

void main() {
  test('parses a Bluetooth address in either spelling', () {
    expect(parseBluetoothAddress('50-0b-91-a9-39-84'), 0x500B91A93984);
    expect(parseBluetoothAddress('50:0B:91:A9:39:84'), 0x500B91A93984);
    expect(() => parseBluetoothAddress('nope'), throwsFormatException);
  });

  test('builds the SOCKADDR_BTH for the Serial Port service lookup', () {
    final bytes = sockaddrBth(0x500B91A93984, service16: 0x1101);
    expect(bytes, hasLength(30));
    expect(bytes.sublist(0, 2), [32, 0]);
    expect(bytes.sublist(2, 10), [0x84, 0x39, 0xA9, 0x91, 0x0B, 0x50, 0, 0]);
    expect(bytes.sublist(10, 26), [0x01, 0x11, 0, 0, 0, 0, 0x00, 0x10, 0x80, 0, 0, 0x80, 0x5F, 0x9B, 0x34, 0xFB]);
    expect(bytes.sublist(26), [0, 0, 0, 0]);
  });

  test('builds the SOCKADDR_BTH for a fixed RFCOMM channel', () {
    final bytes = sockaddrBth(0x500B91A93984, port: 25);
    expect(bytes.sublist(10, 26), everyElement(0));
    expect(bytes.sublist(26), [25, 0, 0, 0]);
  });

  test('reads the paired devices from the device query output', () {
    const output = 'MW75 Neuro|BTHENUM\\DEV_500B91A93984\\7&2845104A&0&BLUETOOTHDEVICE_500B91A93984|OK\r\n'
        'JBL Charge 4|BTHENUM\\DEV_AABBCCDDEEFF\\7&2845104A&0&BLUETOOTHDEVICE_AABBCCDDEEFF|Unknown\r\n'
        'not a device line\r\n';
    final devices = parsePairedDevices(output);
    expect(devices, hasLength(2));
    expect(devices[0].name, 'MW75 Neuro');
    expect(devices[0].address, '50-0b-91-a9-39-84');
    expect(devices[0].connected, isTrue);
    expect(devices[1].name, 'JBL Charge 4');
    expect(devices[1].connected, isFalse);
  });
}
