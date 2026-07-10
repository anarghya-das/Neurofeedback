import 'dart:io';

import 'package:path_provider/path_provider.dart';

class SessionLoggerService {
  File? _logFile;
  final List<String> _entries = [];

  File? get logFile => _logFile;
  List<String> get entries => List.unmodifiable(_entries);

  Future<File> startSession() async {
    final dir = await getApplicationDocumentsDirectory();

    final sessionTime = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');

    _logFile = File('${dir.path}/session_log_$sessionTime.csv');

    await _logFile!.writeAsString(
      'wall_time,lsl_timestamp,graph_time_seconds,event_type,label,message\n',
    );

    _entries.clear();

    await logEvent(
      eventType: 'SESSION_START',
      message: 'Session log started',
    );

    return _logFile!;
  }

  Future<void> logEvent({
    required String eventType,
    String label = '',
    String message = '',
    double? lslTimestamp,
    double? graphTimeSeconds,
  }) async {
    if (_logFile == null) {
      await startSession();
    }

    final wallTime = DateTime.now().toIso8601String();

    final row = [
      _csv(wallTime),
      lslTimestamp == null ? '' : lslTimestamp.toStringAsFixed(9),
      graphTimeSeconds == null ? '' : graphTimeSeconds.toStringAsFixed(6),
      _csv(eventType),
      _csv(label),
      _csv(message),
    ].join(',');

    _entries.add(row);
    await _logFile!.writeAsString('$row\n', mode: FileMode.append);
  }

  Future<File> exportRawEegCsv({
    required List<List<List<double>>> channelSamples,
    required double samplingRate,
  }) async {
    final dir = await getApplicationDocumentsDirectory();

    final exportTime = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');

    final file = File('${dir.path}/raw_eeg_export_$exportTime.csv');

    final channelCount = channelSamples.length;

    final maxLen = channelSamples
        .map((channel) => channel.length)
        .fold<int>(0, (a, b) => a > b ? a : b);

    final buffer = StringBuffer();

    buffer.write('sample_index,time_seconds');

    for (int ch = 0; ch < channelCount; ch++) {
      buffer.write(',ch_${ch + 1}_graph_time_seconds,ch_${ch + 1}_uv');
    }

    buffer.writeln();

    for (int i = 0; i < maxLen; i++) {
      final timeSeconds = samplingRate > 0 ? i / samplingRate : 0.0;

      buffer.write('$i,${timeSeconds.toStringAsFixed(6)}');

      for (int ch = 0; ch < channelCount; ch++) {
        if (i < channelSamples[ch].length) {
          final point = channelSamples[ch][i];
          buffer.write(
            ',${point[0].toStringAsFixed(6)},${point[1].toStringAsFixed(6)}',
          );
        } else {
          buffer.write(',,');
        }
      }

      buffer.writeln();
    }

    await file.writeAsString(buffer.toString());

    await logEvent(
      eventType: 'RAW_EEG_EXPORT',
      label: file.path,
      message: 'Raw EEG buffer exported to CSV',
    );

    return file;
  }

  String _csv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }
}