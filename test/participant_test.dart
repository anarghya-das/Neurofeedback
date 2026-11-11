import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

void main() {
  group('participant on the store', () {
    test('is null until something is typed, and is trimmed', () {
      final store = TestRunStore(Directory.systemTemp);
      expect(store.participantId, isNull);
      store.participant = '   ';
      expect(store.participantId, isNull);
      store.participant = '  P01 ';
      expect(store.participantId, 'P01');
    });
  });

  group('participant on a saved run', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mw75_participant'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('an alpha run keeps it across a save and load', () async {
      final store = TestRunStore(dir);
      final run = AlphaRun(
        started: DateTime(2026, 11, 6, 16, 33),
        settings: const AlphaSettings(),
        binHz: 500 / 512,
        participant: 'P01',
      );
      await (await store.begin(AlphaRun.kind, run.started)).finish(run.toJson());

      final (folder, json) = (await store.load(AlphaRun.kind)).single;
      expect(AlphaRun.fromJson(json, folder: folder).participant, 'P01');
    });

    test('an oddball run keeps it across a save and load', () async {
      final store = TestRunStore(dir);
      final run = OddballRun(
        started: DateTime(2026, 11, 6, 16, 40),
        settings: const OddballSettings(),
        participant: 'P02',
      );
      await (await store.begin(OddballRun.kind, run.started)).finish(run.toJson());

      final (folder, json) = (await store.load(OddballRun.kind)).single;
      expect(OddballRun.fromJson(json, folder: folder).participant, 'P02');
    });

    test('a run saved before participant IDs loads with none', () async {
      final store = TestRunStore(dir);
      final run = AlphaRun(started: DateTime(2026, 10, 9, 3), settings: const AlphaSettings(), binHz: 500 / 512);
      final json = run.toJson()..remove('participant');
      await (await store.begin(AlphaRun.kind, run.started)).finish(json);

      final (folder, saved) = (await store.load(AlphaRun.kind)).single;
      expect(AlphaRun.fromJson(saved, folder: folder).participant, isNull);
    });
  });

  group('the results list', () {
    // A day in the past, so the label never turns into "Today".
    RunItem item(String? participant) =>
        RunItem(started: DateTime(2026, 10, 9, 16, 33), detail: '', included: true, participant: participant);

    test('puts the participant before the time', () {
      expect(RunChecklist.title(item('P01')), 'P01 · Oct 9, 16:33');
    });

    test('shows the time alone when nobody was named', () {
      expect(RunChecklist.title(item(null)), 'Oct 9, 16:33');
    });
  });
}
