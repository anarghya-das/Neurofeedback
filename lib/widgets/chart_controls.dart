import 'package:flutter/material.dart';

/// Widget for chart display controls
class ChartControls extends StatelessWidget {
  final double timeWindowSeconds;
  final double amplitudeScale;
  final Function(double) onTimeWindowChanged;
  final Function(double) onAmplitudeScaleChanged;

  const ChartControls({
    super.key,
    required this.timeWindowSeconds,
    required this.amplitudeScale,
    required this.onTimeWindowChanged,
    required this.onAmplitudeScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          const Text('Time Window (s):'),
          Expanded(
            child: Slider(
              value: timeWindowSeconds,
              min: 1.0,
              max: 10.0,
              divisions: 18,
              label: timeWindowSeconds.toStringAsFixed(1),
              onChanged: onTimeWindowChanged,
            ),
          ),
          const SizedBox(width: 20),
          const Text('Scale:'),
          Expanded(
            child: Slider(
              value: amplitudeScale,
              min: 0.1,
              max: 5.0,
              divisions: 49,
              label: amplitudeScale.toStringAsFixed(1),
              onChanged: onAmplitudeScaleChanged,
            ),
          ),
        ],
      ),
    );
  }
}
