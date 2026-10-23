import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Spoken cues on Windows, through the built-in System.Speech synthesizer.
///
/// One PowerShell process stays open and speaks each line written to it, so only
/// the first cue waits for it to start (about a second). A new line interrupts
/// whatever is still being said; an empty line just stops speaking, like
/// `speak(null)` on macOS.
class WindowsSpeech {
  WindowsSpeech._();

  static final instance = WindowsSpeech._();

  static const _script =
      r'Add-Type -AssemblyName System.Speech; '
      r'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
      r'$s.SetOutputToDefaultAudioDevice(); '
      r'while (($line = [Console]::In.ReadLine()) -ne $null) { '
      r'$s.SpeakAsyncCancelAll(); '
      r'if ($line.Length -gt 0) { [void]$s.SpeakAsync($line) } '
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
