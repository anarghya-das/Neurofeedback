import 'dart:io';

/// On Windows, appends [message] to `%TEMP%\MW75Bench-log.txt`, flushed line by
/// line so the last step before a crash or a silent failure can be read
/// afterwards. A release build has no console, so this file is the only place
/// to see what went wrong. Does nothing on other platforms; never throws.
void appendAppLog(String message) {
  if (!Platform.isWindows) return;
  try {
    final dir = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
    File('$dir\\MW75Bench-log.txt').writeAsStringSync(
      '${DateTime.now().toIso8601String()}  $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}
