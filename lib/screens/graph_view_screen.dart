import 'package:flutter/material.dart';
import '../models/eeg_data_manager.dart';
import '../widgets/chart_controls.dart';
import '../widgets/stacked_eeg_chart.dart';

/// Screen for displaying EEG graphs
class GraphViewScreen extends StatelessWidget {
  final EEGDataManager dataManager;
  final double timeWindowSeconds;
  final double amplitudeScale;
  final Function(double) onTimeWindowChanged;
  final Function(double) onAmplitudeScaleChanged;

  const GraphViewScreen({
    super.key,
    required this.dataManager,
    required this.timeWindowSeconds,
    required this.amplitudeScale,
    required this.onTimeWindowChanged,
    required this.onAmplitudeScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (!dataManager.hasData) {
      return const Center(child: Text('No graph data available'));
    }

    final fullScale = (amplitudeScale >= 20 && amplitudeScale <= 1000)
        ? amplitudeScale
        : 200.0;

    return Column(
      children: [
        ChartControls(
          timeWindowSeconds: timeWindowSeconds,
          amplitudeScale: fullScale,
          onTimeWindowChanged: onTimeWindowChanged,
          onAmplitudeScaleChanged: onAmplitudeScaleChanged,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: StackedEEGChart(
              channelData: dataManager.allChannelData,
              timeWindowSeconds: timeWindowSeconds,
              fullScaleUv: fullScale,
            ),
          ),
        ),
      ],
    );
  }
}
