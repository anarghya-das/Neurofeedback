import 'package:flutter/material.dart';
import '../models/eeg_data_manager.dart';
import '../widgets/eeg_chart.dart';
import '../widgets/chart_controls.dart';

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

    return Column(
      children: [
        ChartControls(
          timeWindowSeconds: timeWindowSeconds,
          amplitudeScale: amplitudeScale,
          onTimeWindowChanged: onTimeWindowChanged,
          onAmplitudeScaleChanged: onAmplitudeScaleChanged,
        ),
        Expanded(
          child: ListView.builder(
            itemCount: dataManager.channelCount,
            itemBuilder: (context, channelIndex) {
              return EEGChart(
                channelData: dataManager.getChannelData(channelIndex),
                channelIndex: channelIndex,
                timeWindowSeconds: timeWindowSeconds,
                amplitudeScale: amplitudeScale,
                title: 'Channel ${channelIndex + 1}',
              );
            },
          ),
        ),
      ],
    );
  }
}
