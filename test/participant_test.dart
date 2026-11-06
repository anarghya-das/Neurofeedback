import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mw75_neuro/mw75_neuro.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mw75_participant'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the participant label is trimmed and empty means none', () {
    final store = TestRunStore(dir);
    expect(store.participantLabel, isNull);
    store.participant.value = '   ';
    expect(store.participantLabel, isNull);
    store.participant.value = '  P01 ';
    expect(store.participantLabel, 'P01');
  });

  test('a run folder ends with the participant, made safe for file names', () async {
    final store = TestRunStore(dir);
    final recorder = await store.begin(AlphaRun.kind, DateTime(2026, 11, 6, 14, 5, 9), participant: 'P01/a:b');
    await recorder.finish({'kind': AlphaRun.kind});
    final name = recorder.folder.uri.pathSegments.where((s) => s.isNotEmpty).last;
    expect(name, 'alpha 2026-11-06 14.05.09 P01_a_b');
    expect(await store.load(AlphaRun.kind), hasLength(1));
  });

  test('without a participant the folder name is unchanged', () async {
    final store = TestRunStore(dir);
    final recorder = await store.begin(AlphaRun.kind, DateTime(2026, 11, 6, 14, 5, 9));
    await recorder.finish({'kind': AlphaRun.kind});
    final name = recorder.folder.uri.pathSegments.where((s) => s.isNotEmpty).last;
    expect(name, 'alpha 2026-11-06 14.05.09');
  });

  test('alpha and oddball runs keep their participant through a save and load', () {
    final alpha = AlphaRun(started: DateTime(2026, 11, 6), settings: const AlphaSettings(), binHz: 1)
      ..participant = 'P02';
    expect(AlphaRun.fromJson(alpha.toJson(), folder: 'x').participant, 'P02');

    final oddball = OddballRun(started: DateTime(2026, 11, 6), settings: const OddballSettings())..participant = 'P03';
    expect(OddballRun.fromJson(oddball.toJson(), folder: 'x').participant, 'P03');

    // Runs saved before labels existed load without one.
    final old = alpha.toJson()..remove('participant');
    expect(AlphaRun.fromJson(old, folder: 'x').participant, isNull);
  });

  testWidgets('the run list shows the participant before the time', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RunChecklist(
            items: [RunItem(started: DateTime(2026, 1, 2, 3, 4), detail: 'd', included: true, participant: 'P04')],
          ),
        ),
      ),
    );
    expect(find.textContaining('P04 · '), findsOneWidget);
  });

  testWidgets('typing in the participant field sets the label', (tester) async {
    final store = TestRunStore(dir);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ParticipantField(store: store))));
    await tester.enterText(find.byType(TextField), 'P05');
    expect(store.participantLabel, 'P05');
  });
}
