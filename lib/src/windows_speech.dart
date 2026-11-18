import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Starts the PowerShell process; replaced in tests.
typedef SpeechProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Spoken cues on Windows, through the built-in System.Speech synthesizer.
///
/// One PowerShell process stays open and speaks each line written to it, so only
/// the first cue waits for it to start (about a second). Lines are spoken one
/// after another with the blocking `Speak`: the first Windows test used
/// `SpeakAsyncCancelAll` + `SpeakAsync` and only the first cue was heard. The
/// cues are short and 20 s apart, so nothing queues up in practice. An empty
/// line (`speak(null)`) is ignored.
///
/// Every step is written to the app log (`%TEMP%\MW75Bench-log.txt`, see
/// app_log.dart), since a failure here is otherwise silent: the process
/// starting or not, the voice it uses, each line spoken, any error PowerShell
/// reports, and the process exiting.
class WindowsSpeech {
  WindowsSpeech({SpeechProcessStarter? start, void Function(String message)? log})
    : _startProcess = start ?? ((executable, arguments) => Process.start(executable, arguments)),
      _log = log ?? appendAppLog;

  static final instance = WindowsSpeech();

  /// Reports on stdout (`ready …`, `spoke …`) and on stderr (`error …`) so each
  /// step reaches the log.
  ///
  /// Each line gets a new synthesizer, bound to the default output as it is at
  /// that moment. One synthesizer for the whole process kept the output it was
  /// given at the start: in the second Windows test the cues were logged as
  /// spoken but nothing was heard, once the MW75's audio had dropped and come
  /// back (output switched, test ended and restarted), until the app was
  /// restarted. A short pause before the words gives a Bluetooth output that
  /// has gone idle time to wake, so the start of a cue is not cut off.
  static const script =
      r'$ErrorActionPreference = "Stop"; '
      r'try { '
      r'Add-Type -AssemblyName System.Speech; '
      r'$probe = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
      r'$voices = @($probe.GetInstalledVoices() | Where-Object { $_.Enabled }).Count; '
      r'[Console]::Out.WriteLine("ready voice=" + $probe.Voice.Name + " voices=" + $voices + " volume=" + $probe.Volume); '
      r'$probe.Dispose(); '
      r'} catch { [Console]::Error.WriteLine("error starting the synthesizer: " + $_); exit 1 } '
      r'while (($line = [Console]::In.ReadLine()) -ne $null) { '
      r'if ($line.Length -gt 0) { '
      r'$s = $null; '
      r'try { '
      r'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
      r'$s.SetOutputToDefaultAudioDevice(); '
      r'$p = New-Object System.Speech.Synthesis.PromptBuilder; '
      r'$p.AppendBreak([TimeSpan]::FromMilliseconds(300)); '
      r'$p.AppendText($line); '
      r'$s.Speak($p); '
      r'[Console]::Out.WriteLine("spoke " + $line) '
      r'} catch { [Console]::Error.WriteLine("error speaking: " + $_) } '
      r'finally { if ($s -ne $null) { $s.Dispose() } } '
      r'} '
      r'}';

  final SpeechProcessStarter _startProcess;
  final void Function(String message) _log;

  Future<Process>? _process;

  void _note(String message) => _log('[speech] $message');

  Future<Process> _start() {
    _note('starting PowerShell (System.Speech)');
    final pending = Future.sync(
      () => _startProcess('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script]),
    );
    _process = pending;
    pending.then(
      (p) {
        _note('PowerShell started, pid ${p.pid}');
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.trim().isNotEmpty) _note(line.trim());
          },
          onError: (Object _) {},
        );
        p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            if (line.trim().isNotEmpty) _note('PowerShell error: ${line.trim()}');
          },
          onError: (Object _) {},
        );
        p.exitCode.then((code) {
          _note('PowerShell exited with code $code');
          if (identical(_process, pending)) _process = null;
        });
      },
      onError: (Object e) {
        _note('could not start PowerShell: $e');
        if (identical(_process, pending)) _process = null;
      },
    );
    return pending;
  }

  /// Starts the synthesizer ahead of the first cue.
  void warmUp() => _process ?? _start();

  Future<void> speak(String? text) async {
    final line = (text ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll(RegExp(r'[^\x20-\x7E]'), ' ');
    try {
      final process = await (_process ?? _start());
      if (line.isNotEmpty) _note('saying "$line"');
      process.stdin.add(ascii.encode('$line\r\n'));
      await process.stdin.flush();
    } catch (e) {
      _note('could not send "$line" to the synthesizer: $e');
      rethrow;
    }
  }
}
