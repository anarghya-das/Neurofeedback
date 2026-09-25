import 'dart:collection';
import 'dart:math' as math;

enum StimulusPhase { baseline, onset, mid, late, postStimulus, idle }

extension StimulusPhaseLabel on StimulusPhase {
  String get label => switch (this) {
    StimulusPhase.baseline => 'Baseline',
    StimulusPhase.onset => 'Onset',
    StimulusPhase.mid => 'Mid',
    StimulusPhase.late => 'Late',
    StimulusPhase.postStimulus => 'Post-stimulus',
    StimulusPhase.idle => 'Idle',
  };
}

class BandPowerFrame {
  final double timeSeconds;
  final List<double> values;

  const BandPowerFrame({required this.timeSeconds, required this.values})
    : assert(values.length == 5);
}

/// Maintains the live, within-subject normalization used by the analysis UI.
///
/// The baseline is the mean PSD from the 10–15 seconds immediately preceding
/// stimulus onset. Ratios are P(real-time) / P(baseline); the dB representation
/// is 10 * log10(ratio).
class LiveEegAnalysis {
  static const bandNames = ['Delta', 'Theta', 'Alpha', 'Beta', 'Gamma'];
  static const onsetSeconds = 0.5;
  static const postStimulusSeconds = 2.0;

  LiveEegAnalysis({double baselineDurationSeconds = 15.0})
    : _baselineDurationSeconds = baselineDurationSeconds;

  final Queue<BandPowerFrame> _rollingBaseline = Queue<BandPowerFrame>();
  final Map<StimulusPhase, List<BandPowerFrame>> _phaseFrames = {};
  final List<BandPowerFrame> _stimulusFrames = [];

  List<double>? _baseline;
  double? _stimulusStart;
  double? _stimulusStop;
  double _stimulusDuration = 2.0;
  double _baselineDurationSeconds;
  bool _baselineCollecting = false;

  double get baselineDurationSeconds => _baselineDurationSeconds;

  List<double>? get baseline =>
      _baseline == null ? null : List<double>.unmodifiable(_baseline!);

  double get baselineCoverageSeconds {
    if (_baseline != null) return _baselineDurationSeconds;
    if (_rollingBaseline.length < 2) return 0;
    return _rollingBaseline.last.timeSeconds -
        _rollingBaseline.first.timeSeconds;
  }

  bool get baselineReady => _baseline != null;
  bool get baselineCollecting => _baselineCollecting;

  void beginBaseline() {
    clear();
    _baselineCollecting = true;
  }

  void addFrame(double timeSeconds, List<double> values) {
    if (values.length != 5 || values.any((value) => !value.isFinite)) return;

    final frame = BandPowerFrame(
      timeSeconds: timeSeconds,
      values: List<double>.from(values),
    );
    if (_baseline == null) {
      if (!_baselineCollecting) return;
      _rollingBaseline.add(frame);
      if (baselineCoverageSeconds >= _baselineDurationSeconds) {
        _baseline = _meanFrames(_rollingBaseline);
        _baselineCollecting = false;
      }
      return;
    }

    final phase = phaseAt(timeSeconds);
    if (phase == StimulusPhase.idle || phase == StimulusPhase.baseline) return;

    _phaseFrames.putIfAbsent(phase, () => []).add(frame);
    if (phase == StimulusPhase.onset ||
        phase == StimulusPhase.mid ||
        phase == StimulusPhase.late) {
      _stimulusFrames.add(frame);
      _phaseFrames.putIfAbsent(StimulusPhase.idle, () => []).add(frame);
    }
  }

  bool startStimulus(double timeSeconds, {required double durationSeconds}) {
    if (_baseline == null) return false;
    _stimulusStart = timeSeconds;
    _stimulusStop = null;
    _stimulusDuration = math.max(durationSeconds, 1.0);
    _phaseFrames.clear();
    _stimulusFrames.clear();
    return true;
  }

  void stopStimulus(double timeSeconds) {
    _stimulusStop = timeSeconds;
    final start = _stimulusStart;
    if (start == null || _stimulusFrames.isEmpty) return;

    // The true stimulus duration is defined by its markers. Reclassifying here
    // makes the final 0.5 s the late window even when playback is stopped early.
    _stimulusDuration = math.max(timeSeconds - start, 1.0);
    _phaseFrames.remove(StimulusPhase.onset);
    _phaseFrames.remove(StimulusPhase.mid);
    _phaseFrames.remove(StimulusPhase.late);
    _phaseFrames[StimulusPhase.idle] = List<BandPowerFrame>.from(
      _stimulusFrames,
    );

    for (final frame in _stimulusFrames) {
      final elapsed = frame.timeSeconds - start;
      final isOnset = elapsed <= onsetSeconds;
      final isLate = frame.timeSeconds >= timeSeconds - onsetSeconds;

      // On sounds shorter than one second, onset and late legitimately overlap.
      // Keep the frame in both summaries so neither result is left blank.
      if (isOnset) {
        _phaseFrames.putIfAbsent(StimulusPhase.onset, () => []).add(frame);
      }
      if (isLate) {
        _phaseFrames.putIfAbsent(StimulusPhase.late, () => []).add(frame);
      }
      if (!isOnset && !isLate) {
        _phaseFrames.putIfAbsent(StimulusPhase.mid, () => []).add(frame);
      }
    }
  }

  StimulusPhase phaseAt(double timeSeconds) {
    final start = _stimulusStart;
    if (start == null) return StimulusPhase.idle;

    final elapsed = timeSeconds - start;
    if (elapsed < 0) return StimulusPhase.baseline;

    final stop = _stimulusStop;
    if (stop != null && timeSeconds >= stop) {
      return timeSeconds <= stop + postStimulusSeconds
          ? StimulusPhase.postStimulus
          : StimulusPhase.idle;
    }

    if (elapsed <= onsetSeconds) return StimulusPhase.onset;
    if (elapsed >= _stimulusDuration - onsetSeconds) {
      return StimulusPhase.late;
    }
    return StimulusPhase.mid;
  }

  List<double>? ratiosFor(List<double> current) {
    final base = _baseline;
    if (base == null || current.length != 5) return null;
    return List<double>.generate(5, (index) {
      final denominator = base[index];
      return denominator > 0 ? current[index] / denominator : 0;
    });
  }

  List<double>? decibelsFor(List<double> current) {
    final ratios = ratiosFor(current);
    if (ratios == null) return null;
    return ratios
        .map((ratio) => ratio > 0 ? 10 * math.log(ratio) / math.ln10 : 0.0)
        .toList();
  }

  List<double>? phaseRatios(StimulusPhase phase) {
    final base = _baseline;
    if (base == null) return null;
    final frames = phase == StimulusPhase.idle
        ? _phaseFrames[StimulusPhase.idle]
        : _phaseFrames[phase];
    if (frames == null || frames.isEmpty) return null;
    return ratiosFor(_meanFrames(frames));
  }

  List<double>? get sustainedRatios => phaseRatios(StimulusPhase.idle);

  List<double> _meanFrames(Iterable<BandPowerFrame> frames) {
    final sums = List<double>.filled(5, 0);
    var count = 0;
    for (final frame in frames) {
      for (var i = 0; i < sums.length; i++) {
        sums[i] += frame.values[i];
      }
      count++;
    }
    if (count == 0) return sums;
    return sums.map((sum) => sum / count).toList();
  }

  void clear() {
    _rollingBaseline.clear();
    _phaseFrames.clear();
    _stimulusFrames.clear();
    _baseline = null;
    _stimulusStart = null;
    _stimulusStop = null;
    _baselineCollecting = false;
  }

  void configureBaselineDuration(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return;
    _baselineDurationSeconds = seconds;
    clear();
  }
}
