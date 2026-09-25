import 'package:flutter/material.dart';

import '../models/live_eeg_analysis.dart';
import 'neural_orb.dart';

class LiveAnalysisPanel extends StatelessWidget {
  final LiveEegAnalysis analysis;
  final List<double> currentPower;
  final double graphTimeSeconds;
  final int completedTrialCount;

  const LiveAnalysisPanel({
    super.key,
    required this.analysis,
    required this.currentPower,
    required this.graphTimeSeconds,
    required this.completedTrialCount,
  });

  @override
  Widget build(BuildContext context) {
    final liveRatios = analysis.ratiosFor(currentPower);
    final phase = analysis.phaseAt(graphTimeSeconds);

    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  analysis.baselineReady
                      ? 'Baseline fixed • ${analysis.baselineDurationSeconds.toStringAsFixed(1)} s'
                      : !analysis.baselineCollecting
                      ? 'Waiting for Start Experiment'
                      : 'Collecting baseline • ${analysis.baselineCoverageSeconds.toStringAsFixed(1)} / ${analysis.baselineDurationSeconds.toStringAsFixed(1)} s',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: analysis.baselineReady
                        ? const Color(0xFF15803D)
                        : analysis.baselineCollecting
                        ? const Color(0xFFB45309)
                        : const Color(0xFF64748B),
                  ),
                ),
              ),
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  phase == StimulusPhase.idle ? 'Continuous' : phase.label,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'PSD'),
              Tab(text: 'ERP'),
              Tab(text: 'Connectivity'),
              Tab(text: 'Time–frequency'),
            ],
          ),
          SizedBox(
            height: 300,
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.only(top: 12),
                  children: [
                    const Text(
                      'Live neural field',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 205,
                      child: NeuralOrb(
                        ratios: liveRatios,
                        calibrating: analysis.baselineCollecting,
                        ready: analysis.baselineReady,
                      ),
                    ),
                    const Center(
                      child: Text(
                        'Color = band with largest change • Brightness = distance from baseline',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ],
                ),
                _MethodStatus(
                  title: 'Event-related potentials (ERP)',
                  ready: completedTrialCount >= 2,
                  message: completedTrialCount >= 2
                      ? '$completedTrialCount completed trials available. Trial-locked averaging is ready for offline N1, P2, P3, LSP, LPP, and VLC extraction.'
                      : 'ERP requires at least two repeated, marker-aligned trials. Complete more trials before interpreting an evoked response.',
                ),
                const _MethodStatus(
                  title: 'Functional connectivity',
                  ready: false,
                  message:
                      'Connectivity should be computed over full saved epochs using wPLI and imaginary coherence. Short 0.5 s onset/late windows are intentionally excluded for δ and θ because they contain too few cycles.',
                ),
                const _MethodStatus(
                  title: 'Time–frequency representation',
                  ready: false,
                  message:
                      'The phase-resolved band history is being retained for the live PSD summary. A publication-grade TFR requires marker-aligned epochs and Morlet analysis from the saved session.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MethodStatus extends StatelessWidget {
  final String title;
  final bool ready;
  final String message;

  const _MethodStatus({
    required this.title,
    required this.ready,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ready ? Icons.check_circle_outline : Icons.science_outlined,
              size: 36,
              color: ready ? const Color(0xFF15803D) : const Color(0xFF64748B),
            ),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF596273), height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
