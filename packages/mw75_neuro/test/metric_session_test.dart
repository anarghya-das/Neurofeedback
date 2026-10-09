import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

/// A 128-byte focus record with [focus] at byte 120, split into BLE chunks of
/// [chunkSize] payload bytes.
List<Uint8List> chunks(double focus, {int chunkSize = 20}) {
  final record = ByteData(128)..setFloat32(120, focus, Endian.little);
  final bytes = record.buffer.asUint8List();
  return [
    for (var i = 0, start = 0; start < 128; i++, start += chunkSize)
      Uint8List.fromList([
        0x09, 0x9A, 0x03, 0x84, 0xAA, 0xFC, //
        (128 - start).clamp(0, chunkSize), i & 0xFF, i >> 8,
        ...bytes.sublist(start, (start + chunkSize).clamp(0, 128)),
      ]),
  ];
}

void main() {
  test('reassembles a record split across chunks and reads focus at byte 120', () {
    final a = FocusRecordAssembler();
    final parts = chunks(0.72);
    expect(parts, hasLength(7));
    final results = [for (final c in parts) a.add(c)];
    expect(results.take(6), everyElement(FocusResult.pending));
    expect(results.last, FocusResult.ready);
    expect(a.focus, closeTo(0.72, 1e-6));
  });

  test('drops a partial record when a chunk goes missing, then recovers', () {
    final a = FocusRecordAssembler();
    final first = chunks(0.30);
    a.add(first[0]);
    a.add(first[1]);
    expect(a.add(first[3]), FocusResult.outOfOrder); // chunk 2 lost
    // Chunks that are not a record start are ignored until the next chunk 0.
    expect(a.add(first[4]), FocusResult.outOfOrder);
    final second = chunks(0.55);
    final results = [for (final c in second) a.add(c)];
    expect(results.last, FocusResult.ready);
    expect(a.focus, closeTo(0.55, 1e-6));
  });

  test('rejects a non-numeric focus value', () {
    final a = FocusRecordAssembler();
    final results = [for (final c in chunks(double.nan)) a.add(c)];
    expect(results.last, FocusResult.invalid);
    expect(a.focus, isNull);
  });

  test('recognises only focus chunks', () {
    expect(FocusRecordAssembler.isChunk(chunks(0.5).first), isTrue);
    // The per-cup contact message and a command reply are not chunks.
    expect(FocusRecordAssembler.isChunk([0x09, 0x9A, 0x03, 0xE1, 0x05, 0x05]), isFalse);
    expect(FocusRecordAssembler.isChunk([0x09, 0x9A, 0x03, 0x35, 0xF1, 0x00, 0x00, 0x00, 0x00]), isFalse);
  });
}
