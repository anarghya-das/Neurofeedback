import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/src/windows_speech.dart';

/// Stands in for the PowerShell process: records what is written to it and
/// lets the test emit stdout/stderr lines and an exit code.
class _FakeProcess implements Process {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  final written = <String>[];
  late final _FakeSink _sink = _FakeSink(written);

  void out(String line) => _stdout.add(utf8.encode('$line\r\n'));
  void err(String line) => _stderr.add(utf8.encode('$line\r\n'));
  void exit(int code) {
    _stdout.close();
    _stderr.close();
    _exit.complete(code);
  }

  @override
  int get pid => 4242;
  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _sink;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _FakeSink implements IOSink {
  _FakeSink(this.written);
  final List<String> written;

  @override
  void add(List<int> data) => written.add(ascii.decode(data));
  @override
  Future<void> flush() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  test('logs the start, the voice, each cue and PowerShell errors', () async {
    final log = <String>[];
    final process = _FakeProcess();
    final arguments = <List<String>>[];
    final speech = WindowsSpeech(
      start: (executable, args) async {
        arguments.add([executable, ...args]);
        return process;
      },
      log: log.add,
    );

    await speech.speak('Close your eyes.');
    expect(arguments.single.first, 'powershell.exe');
    expect(arguments.single.last, WindowsSpeech.script);
    expect(process.written, ['Close your eyes.\r\n']);

    process.out('ready voice=Microsoft David Desktop voices=2 volume=100');
    process.err('error speaking: no audio device');
    await _settle();

    expect(log, [
      '[speech] starting PowerShell (System.Speech)',
      '[speech] PowerShell started, pid 4242',
      '[speech] saying "Close your eyes."',
      '[speech] ready voice=Microsoft David Desktop voices=2 volume=100',
      '[speech] PowerShell error: error speaking: no audio device',
    ]);

    // One process for every cue.
    await speech.speak('Open your eyes.');
    expect(arguments, hasLength(1));
    expect(process.written.last, 'Open your eyes.\r\n');

    process.exit(1);
    await _settle();
    expect(log.last, '[speech] PowerShell exited with code 1');

    // After it exits the next cue starts a new one.
    final second = _FakeProcess();
    final speech2Log = <String>[];
    final speech2 = WindowsSpeech(start: (_, _) async => second, log: speech2Log.add);
    await speech2.speak(null);
    expect(second.written, ['\r\n']);
    expect(speech2Log.where((l) => l.contains('saying')), isEmpty);
  });

  test('logs a PowerShell that cannot start and reports the failure', () async {
    final log = <String>[];
    var starts = 0;
    final speech = WindowsSpeech(
      start: (_, _) async {
        starts++;
        throw const ProcessException('powershell.exe', [], 'The system cannot find the file specified.', 2);
      },
      log: log.add,
    );

    await expectLater(speech.speak('Close your eyes.'), throwsA(isA<ProcessException>()));
    await _settle();
    expect(log.where((l) => l.startsWith('[speech] could not start PowerShell')), hasLength(1));
    expect(log.where((l) => l.startsWith('[speech] could not send "Close your eyes."')), hasLength(1));

    // The next cue tries again rather than reusing the failed start.
    await expectLater(speech.speak('Open your eyes.'), throwsA(isA<ProcessException>()));
    expect(starts, 2);
  });

  test('the cue is sent as one printable ASCII line', () async {
    final process = _FakeProcess();
    final speech = WindowsSpeech(start: (_, _) async => process, log: (_) {});
    await speech.speak('Eyes\r\nclosed — now');
    expect(process.written.single, 'Eyes closed   now\r\n');
  });

  test('each cue gets a synthesizer bound to the output in use at that moment', () {
    // A synthesizer made once kept the output it started on, and cues went
    // silent after the MW75's audio dropped and came back.
    const script = WindowsSpeech.script;
    final loop = script.indexOf('while (');
    expect(loop, greaterThan(0));
    final perLine = script.substring(loop);
    expect(perLine, contains('New-Object System.Speech.Synthesis.SpeechSynthesizer'));
    expect(perLine, contains('SetOutputToDefaultAudioDevice()'));
    expect(perLine, contains('Dispose()'));
    expect(script.substring(0, loop), isNot(contains('SetOutputToDefaultAudioDevice')));
  });
}
