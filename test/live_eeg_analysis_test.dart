import 'package:eeg_viewer_lsl/models/live_eeg_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not collect baseline until experiment starts', () {
    final analysis = LiveEegAnalysis(baselineDurationSeconds: 1);
    for (var i = 0; i <= 20; i++) {
      analysis.addFrame(i / 10, const [1, 1, 1, 1, 1]);
    }

    expect(analysis.baselineReady, isFalse);
    expect(analysis.baselineCoverageSeconds, 0);
  });

  test('automatically fixes the configured initial baseline', () {
    final analysis = LiveEegAnalysis(baselineDurationSeconds: 10);
    analysis.beginBaseline();
    for (var i = 0; i <= 120; i++) {
      analysis.addFrame(i / 10, const [1, 2, 4, 8, 16]);
    }

    expect(analysis.baselineReady, isTrue);
    analysis.addFrame(12.1, const [100, 100, 100, 100, 100]);
    expect(analysis.startStimulus(12, durationSeconds: 2), isTrue);
    expect(
      analysis.ratiosFor(const [2, 4, 8, 16, 32]),
      everyElement(closeTo(2, 1e-9)),
    );
  });

  test('classifies onset, mid, late, and post-stimulus windows', () {
    final analysis = LiveEegAnalysis(baselineDurationSeconds: 10);
    analysis.beginBaseline();
    for (var i = 0; i <= 100; i++) {
      analysis.addFrame(i / 10, const [1, 1, 1, 1, 1]);
    }
    analysis.startStimulus(10, durationSeconds: 2);

    expect(analysis.phaseAt(10.2), StimulusPhase.onset);
    expect(analysis.phaseAt(11), StimulusPhase.mid);
    expect(analysis.phaseAt(11.7), StimulusPhase.late);
    analysis.stopStimulus(12);
    expect(analysis.phaseAt(12.5), StimulusPhase.postStimulus);
  });

  test('uses the actual stop time for late when audio stops early', () {
    final analysis = LiveEegAnalysis(baselineDurationSeconds: 10);
    analysis.beginBaseline();
    for (var i = 0; i <= 100; i++) {
      analysis.addFrame(i / 10, const [1, 1, 1, 1, 1]);
    }
    analysis.startStimulus(10, durationSeconds: 120);
    for (var i = 1; i <= 30; i++) {
      analysis.addFrame(10 + i / 10, const [2, 2, 2, 2, 2]);
    }

    analysis.stopStimulus(13);

    expect(analysis.phaseRatios(StimulusPhase.late), isNotNull);
    expect(
      analysis.phaseRatios(StimulusPhase.late),
      everyElement(closeTo(2, 1e-9)),
    );
  });

  test('short sounds can use the same frames for onset and late', () {
    final analysis = LiveEegAnalysis(baselineDurationSeconds: 10);
    analysis.beginBaseline();
    for (var i = 0; i <= 100; i++) {
      analysis.addFrame(i / 10, const [1, 1, 1, 1, 1]);
    }
    analysis.startStimulus(10, durationSeconds: 0.4);
    for (var i = 1; i <= 4; i++) {
      analysis.addFrame(10 + i / 10, const [3, 3, 3, 3, 3]);
    }

    analysis.stopStimulus(10.4);

    expect(analysis.phaseRatios(StimulusPhase.onset), isNotNull);
    expect(analysis.phaseRatios(StimulusPhase.late), isNotNull);
  });
}
