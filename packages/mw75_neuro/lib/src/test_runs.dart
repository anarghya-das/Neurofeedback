import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'stream_processor.dart';

/// Keeps finished test runs on disk so they survive the app closing and can be
/// pooled across sessions or analysed offline.
///
/// Each run gets a folder under [directory] named after its kind and start
/// time, holding `run.json` (settings and results, enough to pool it again
/// later) and `eeg.csv` (every EEG sample recorded during the run).
class TestRunStore {
  TestRunStore(this.directory);

  final Directory directory;

  /// Creates the folder for a run of [kind] starting at [started].
  Future<RunRecorder> begin(String kind, DateTime started) async {
    final folder = Directory('${directory.path}/$kind ${_stamp(started)}');
    await folder.create(recursive: true);
    return RunRecorder._(folder);
  }

  /// Saved runs of [kind], newest first, as (folder, run.json contents).
  /// Folders without a readable run.json are skipped.
  Future<List<(String, Map<String, Object?>)>> load(String kind) async {
    if (!await directory.exists()) return const [];
    final runs = <(String, Map<String, Object?>)>[];
    await for (final entry in directory.list()) {
      if (entry is! Directory || !_name(entry).startsWith('$kind ')) continue;
      try {
        final json = jsonDecode(await File('${entry.path}/run.json').readAsString());
        if (json is Map<String, Object?> && json['kind'] == kind) runs.add((entry.path, json));
      } catch (_) {}
    }
    runs.sort((a, b) => b.$1.compareTo(a.$1));
    return runs;
  }

  static String _name(Directory d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last;

  /// `2026-10-09 02.01.51`: sorts by time and is valid in a file name.
  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
  }
}

/// Writes one run's EEG as it arrives and its results when it ends.
class RunRecorder {
  RunRecorder._(this.folder) : _eeg = File('${folder.path}/eeg.csv').openWrite() {
    _eeg.writeln([
      'lsl_time',
      for (var c = 1; c <= Mw75Protocol.eegChannelCount; c++) 'ch${c}_uV',
      'sample_status',
    ].join(','));
  }

  final Directory folder;
  final IOSink _eeg;
  bool _closed = false;

  /// `sample_status` uses [SampleStatus]: 0 measured, 1 interpolated,
  /// 2 measured after a long dropout.
  void addSamples(List<Mw75Sample> samples) {
    if (_closed) return;
    final out = StringBuffer();
    for (final s in samples) {
      out.write(s.time.toStringAsFixed(6));
      for (var c = 0; c < Mw75Protocol.eegChannelCount; c++) {
        out
          ..write(',')
          ..write(s.values[c].toStringAsFixed(3));
      }
      out
        ..write(',')
        ..writeln(s.status);
    }
    _eeg.write(out);
  }

  /// Closes the EEG file and writes `run.json`.
  Future<void> finish(Map<String, Object?> run) async {
    await _close();
    await File('${folder.path}/run.json').writeAsString(jsonEncode(run));
  }

  /// Closes the EEG file and removes the folder, for runs with nothing worth
  /// keeping.
  Future<void> discard() async {
    await _close();
    try {
      await folder.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _eeg.flush();
    await _eeg.close();
  }
}

/// Rounds to 3 decimals for compact JSON (µV to the nanovolt).
double round3(double v) => (v * 1000).roundToDouble() / 1000;
