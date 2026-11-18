import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/src/windows_speech.dart';

/// Stands in for one PowerShell run: the test emits stdout/stderr lines and
/// decides when it exits.
class _FakeProcess implements Process {
  _FakeProcess(this.arguments);
  final List<String> arguments;

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  String get command => arguments.last;

  void out(String line) => _stdout.add(utf8.encode('$line\r\n'));
  void err(String line) => _stderr.add(utf8.encode('$line\r\n'));
  void finish(int code) {
    if (_exit.isCompleted) return;
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
  IOSink get stdin => _NullSink();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    finish(-1);
    return true;
  }
}

class _NullSink implements IOSink {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late List<_FakeProcess> started;
  late List<String> log;
  late WindowsSpeech speech;

  setUp(() {
    started = [];
    log = [];
    speech = WindowsSpeech(
      start: (executable, arguments) async {
        expect(executable, 'powershell.exe');
        final p = _FakeProcess(arguments);
        started.add(p);
        return p;
      },
      log: log.add,
    );
  });

  // The second Windows test: one long-lived PowerShell fed lines on stdin
  // spoke the first two cues and then nothing, with no error. Every cue now
  // gets its own process.
  test('each cue runs its own PowerShell, one after another', () async {
    final first = speech.speak('Eyes open.');
    final second = speech.speak('Close your eyes.');
    await _settle();
    expect(started, hasLength(1), reason: 'the second waits for the first');
    expect(started[0].command, contains("AppendText('Eyes open.')"));

    started[0].out('spoke voice=Microsoft David Desktop');
    started[0].finish(0);
    await first;
    await _settle();
    expect(started, hasLength(2));
    expect(started[1].command, contains("AppendText('Close your eyes.')"));
    started[1].finish(0);
    await second;

    expect(log, [
      '[speech] saying "Eyes open."',
      '[speech] saying "Close your eyes."',
      '[speech] spoke voice=Microsoft David Desktop: "Eyes open."',
    ]);
  });

  test('a later cue still plays when an earlier one fails, hangs or cannot start', () async {
    final failing = WindowsSpeech(
      start: (_, arguments) async {
        if (arguments.last.contains('cannot start')) {
          throw const ProcessException('powershell.exe', [], 'not found', 2);
        }
        final p = _FakeProcess(arguments);
        started.add(p);
        return p;
      },
      log: log.add,
    );
    await failing.speak('cannot start');
    final bad = failing.speak('bad');
    await _settle();
    started.last
      ..err('error speaking: no audio device')
      ..finish(1);
    await bad;
    final good = failing.speak('good');
    await _settle();
    started.last.finish(0);
    await good;

    expect(log, contains(startsWith('[speech] could not start PowerShell for "cannot start"')));
    expect(log, contains('[speech] PowerShell error: error speaking: no audio device'));
    expect(log, contains('[speech] PowerShell exited with code 1 for "bad"'));
    expect(started.last.command, contains("AppendText('good')"));
  });

  test('speak(null) stops the cue playing and drops the queued ones', () async {
    unawaited(speech.speak('Keep your eyes open.'));
    final queued = speech.speak('Eyes open.');
    await _settle();
    await speech.speak(null);
    await queued;
    expect(started.single.killed, isTrue);
    expect(log, contains('[speech] dropped "Eyes open."'));
  });

  test('words are one printable line, with quotes escaped for PowerShell', () async {
    unawaited(speech.speak("Eyes\r\nclosed — it's time"));
    await _settle();
    expect(started.single.command, contains("AppendText('Eyes closed   it''s time')"));
    started.single.finish(0);
  });

  test('the command binds the current output and pauses before the words', () {
    final script = WindowsSpeech.scriptFor('Close your eyes.');
    expect(script, contains('SetOutputToDefaultAudioDevice()'));
    expect(script, contains('AppendBreak'));
    expect(script.indexOf('AppendBreak'), lessThan(script.indexOf('AppendText')));
  });
}
