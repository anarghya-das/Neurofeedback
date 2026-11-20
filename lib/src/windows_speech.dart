import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Starts a PowerShell process; replaced in tests.
typedef SpeechProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Spoken cues on Windows, through the built-in System.Speech synthesizer.
///
/// Each cue runs its own short PowerShell, with the words in its command line,
/// and the cues play one after another. The earlier design, one PowerShell
/// kept open and fed lines on stdin, went quiet after its first two lines in
/// the second Windows test: the log showed every later cue sent and none
/// spoken, with no error and the process still running. A new process per cue
/// takes about a second to start, which the settling time after each cue
/// (4 s or more) absorbs.
///
/// Every step is written to the app log (`%TEMP%\MW75Bench-log.txt`, see
/// app_log.dart), since a failure here is otherwise silent.
class WindowsSpeech {
  WindowsSpeech({SpeechProcessStarter? start, void Function(String message)? log})
    : _startProcess = start ?? ((executable, arguments) => Process.start(executable, arguments)),
      _log = log ?? appendAppLog;

  static final instance = WindowsSpeech();

  /// A cue still waiting after this long is given up, so a stuck PowerShell
  /// cannot hold back the cues after it.
  static const timeout = Duration(seconds: 20);

  /// The PowerShell command that speaks [text]: a new synthesizer on the
  /// default output as it is now, a short pause so a Bluetooth output that has
  /// gone idle can wake before the words, then the words. Prints `spoke` when
  /// done, or `error speaking: …` on stderr.
  static String scriptFor(String text) {
    final quoted = text.replaceAll("'", "''");
    return r'$ErrorActionPreference = "Stop"; '
        r'try { '
        r'Add-Type -AssemblyName System.Speech; '
        r'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
        r'$s.SetOutputToDefaultAudioDevice(); '
        // A female US English voice like the Mac app's (Samantha): Zira, else
        // the closest Windows has. The default, David, is male.
        r'try { $s.SelectVoice("Microsoft Zira Desktop") } catch { '
        r'try { $s.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, '
        r'[System.Speech.Synthesis.VoiceAge]::Adult, 0, [System.Globalization.CultureInfo]::GetCultureInfo("en-US")) } catch { } '
        r'} '
        r'$p = New-Object System.Speech.Synthesis.PromptBuilder; '
        r'$p.AppendBreak([TimeSpan]::FromMilliseconds(300)); '
        "\$p.AppendText('$quoted'); "
        r'$s.Speak($p); '
        r'[Console]::Out.WriteLine("spoke voice=" + $s.Voice.Name); '
        r'$s.Dispose() '
        r'} catch { [Console]::Error.WriteLine("error speaking: " + $_); exit 1 }';
  }

  final SpeechProcessStarter _startProcess;
  final void Function(String message) _log;

  /// The cue playing now, and the end of the queue.
  Process? _current;
  Future<void> _queue = Future.value();

  /// Bumped by [speak] (null) to drop the cues still queued.
  int _generation = 0;

  void _note(String message) => _log('[speech] $message');

  /// Nothing to start ahead of time: each cue has its own process.
  void warmUp() {}

  /// Speaks [text] after any cue still playing. Null stops the cue playing now
  /// and drops the queued ones. Completes when [text] has been spoken, given up
  /// or failed; never throws, since every outcome is in the log.
  Future<void> speak(String? text) {
    if (text == null) {
      _generation++;
      _current?.kill();
      return Future.value();
    }
    final line = text.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll(RegExp(r'[^\x20-\x7E]'), ' ').trim();
    if (line.isEmpty) return Future.value();
    final generation = _generation;
    _note('saying "$line"');
    final done = _queue.then((_) async {
      if (generation != _generation) {
        _note('dropped "$line"');
        return;
      }
      await _say(line);
    });
    // A failure must not stop the cues after it.
    _queue = done.catchError((Object _) {});
    return _queue;
  }

  Future<void> _say(String line) async {
    final Process process;
    try {
      process = await _startProcess('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        scriptFor(line),
      ]);
    } catch (e) {
      _note('could not start PowerShell for "$line": $e');
      return;
    }
    _current = process;
    // Read to the end, so lines printed just before exiting are not lost.
    final out = process.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
      if (l.trim().isNotEmpty) _note('${l.trim()}: "$line"');
    }).catchError((Object _) {});
    final err = process.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
      if (l.trim().isNotEmpty) _note('PowerShell error: ${l.trim()}');
    }).catchError((Object _) {});
    unawaited(process.stdin.close().catchError((Object _) {}));
    try {
      final code = await process.exitCode.timeout(timeout);
      await Future.wait([out, err]).timeout(const Duration(seconds: 2), onTimeout: () => const []);
      if (code != 0) _note('PowerShell exited with code $code for "$line"');
    } on TimeoutException {
      _note('gave up on "$line" after ${timeout.inSeconds} s');
      process.kill();
    } finally {
      if (identical(_current, process)) _current = null;
    }
  }
}
