import 'package:flutter/material.dart';
import '../widgets/band_power_bar_chart.dart';

class BandPowerScreen extends StatelessWidget {
  final double deltaRaw;
  final double thetaRaw;
  final double alphaRaw;
  final double betaRaw;
  final double gammaRaw;

  final double? baselineDelta;
  final double? baselineTheta;
  final double? baselineAlpha;
  final double? baselineBeta;
  final double? baselineGamma;

  final bool stimulusActive;
  final String? activeStimulusLabel;
  final DateTime? stimulusStartTime;

  const BandPowerScreen({
    super.key,
    required this.deltaRaw,
    required this.thetaRaw,
    required this.alphaRaw,
    required this.betaRaw,
    required this.gammaRaw,
    required this.baselineDelta,
    required this.baselineTheta,
    required this.baselineAlpha,
    required this.baselineBeta,
    required this.baselineGamma,
    required this.stimulusActive,
    required this.activeStimulusLabel,
    required this.stimulusStartTime,
  });

  String _fmtDelta(double? baseline, double current) {
    if (baseline == null || baseline <= 0) return '—';
    final diff = current - baseline;
    final sign = diff >= 0 ? '+' : '';
    return '$sign${diff.toStringAsFixed(3)}';
  }

  Widget _changeChip(String label, double? baseline, double current) {
    final text = _fmtDelta(baseline, current);
    final diff = baseline == null ? 0.0 : current - baseline;
    final Color bg = baseline == null
        ? Colors.grey.shade200
        : diff >= 0
            ? Colors.green.shade100
            : Colors.red.shade100;

    final Color fg = baseline == null
        ? Colors.grey.shade700
        : diff >= 0
            ? Colors.green.shade800
            : Colors.red.shade800;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(text, style: TextStyle(color: fg, fontSize: 13)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = (stimulusActive && stimulusStartTime != null)
        ? DateTime.now().difference(stimulusStartTime!).inSeconds
        : null;

    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Band Power',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: stimulusActive ? Colors.blue.shade50 : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: stimulusActive ? Colors.blue.shade200 : Colors.grey.shade300,
              ),
            ),
            child: Text(
              stimulusActive
                  ? 'Stimulus active: ${activeStimulusLabel ?? "unknown"}'
                    '${elapsed != null ? " • ${elapsed}s" : ""}'
                  : 'No active stimulus. Press Test Start in the app bar or wire your audio Play button to onAudioStartMarker(...).',
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _changeChip('Δ Delta', baselineDelta, deltaRaw),
              _changeChip('Θ Theta', baselineTheta, thetaRaw),
              _changeChip('Α Alpha', baselineAlpha, alphaRaw),
              _changeChip('Β Beta', baselineBeta, betaRaw),
              _changeChip('Γ Gamma', baselineGamma, gammaRaw),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: BandPowerBarChart(
              delta: deltaRaw,
              theta: thetaRaw,
              alpha: alphaRaw,
              beta: betaRaw,
              gamma: gammaRaw,
              baselineDelta: baselineDelta,
              baselineTheta: baselineTheta,
              baselineAlpha: baselineAlpha,
              baselineBeta: baselineBeta,
              baselineGamma: baselineGamma,
            ),
          ),
        ],
      ),
    );
  }
}