import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Spoken cues on Windows, through the built-in System.Speech synthesizer.
///
/// One PowerShell process stays open and speaks each line written to it, so only
/// the first cue waits for it to start (about a second). Lines are spoken one
/// after another with the blocking `Speak`: the first Windows test used
/// `SpeakAsyncCancelAll` + `SpeakAsync` and only the first cue was heard. The
/// cues are short and 20 s apart, so nothing queues up in practice. An empty
/// line (`speak(null)`) is ignored.
class WindowsSpeech {
  WindowsSpeech._();

  static final instance = WindowsSpeech._();

  static const _script =
      r'Add-Type -AssemblyName System.Speech; '
      r'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
      r'$s.SetOutputToDefaultAudioDevice(); '
      r'while (($line = [Console]::In.ReadLine()) -ne $null) { '
      r'if ($line.Length -gt 0) { try { $s.Speak($line) } catch { } } '
      r'}';

  Future<Process>? _process;

  Future<Process> _start() {
    final pending = Process.start('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', _script]);
    _process = pending;
    pending.then(
      (p) {
        p.stdout.drain<void>();
        p.stderr.drain<void>();
        p.exitCode.then((_) {
          if (identical(_process, pending)) _process = null;
        });
      },
      onError: (Object _) {
        if (identical(_process, pending)) _process = null;
      },
    );
    return pending;
  }

  /// Starts the synthesizer ahead of the first cue.
  void warmUp() => _process ?? _start();

  Future<void> speak(String? text) async {
    final process = await (_process ?? _start());
    final line = (text ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ');
    process.stdin.add(ascii.encode('${line.replaceAll(RegExp(r'[^\x20-\x7E]'), ' ')}\r\n'));
    await process.stdin.flush();
  }
}
