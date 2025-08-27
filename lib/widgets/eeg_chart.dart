import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:collection';
import 'dart:math' as math;
import '../utils/chart_utils.dart';

/// Widget for displaying real-time EEG data charts
class EEGChart extends StatelessWidget {
  final Queue<FlSpot> channelData;
  final int channelIndex;
  final double timeWindowSeconds;
  final double amplitudeScale;
  final String title;

  const EEGChart({
    super.key,
    required this.channelData,
    required this.channelIndex,
    required this.timeWindowSeconds,
    required this.amplitudeScale,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(
              height: 150,
              child: channelData.isNotEmpty
                  ? LineChart(_buildLineChartData())
                  : const Center(child: Text('No data')),
            ),
          ],
        ),
      ),
    );
  }

  LineChartData _buildLineChartData() {
    if (channelData.isEmpty) {
      return LineChartData(lineBarsData: []);
    }

    List<FlSpot> spots = channelData.toList();

    // Calculate Y-axis range
    double minY = spots.map((spot) => spot.y).reduce(math.min) * amplitudeScale;
    double maxY = spots.map((spot) => spot.y).reduce(math.max) * amplitudeScale;
    double range = maxY - minY;
    if (range == 0) range = 1.0;

    // Adjust Y values by scale
    List<FlSpot> scaledSpots = spots
        .map((spot) => FlSpot(spot.x, spot.y * amplitudeScale))
        .toList();

    return LineChartData(
      lineBarsData: [
        LineChartBarData(
          spots: scaledSpots,
          isCurved: false,
          color: ChartUtils.getChannelColor(channelIndex),
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
        ),
      ],
      minX: spots.isNotEmpty ? spots.last.x - timeWindowSeconds : 0,
      maxX: spots.isNotEmpty ? spots.last.x : timeWindowSeconds,
      minY: minY - range * 0.1,
      maxY: maxY + range * 0.1,
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, meta) {
              return Text(
                ChartUtils.formatTime(value),
                style: const TextStyle(fontSize: 10),
              );
            },
            reservedSize: 30,
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, meta) {
              return Text(
                ChartUtils.formatAmplitude(value),
                style: const TextStyle(fontSize: 10),
              );
            },
            reservedSize: 50,
          ),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
      ),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: true,
        drawHorizontalLine: true,
        getDrawingHorizontalLine: (value) =>
            FlLine(color: Colors.grey.withValues(alpha: 0.3), strokeWidth: 0.5),
        getDrawingVerticalLine: (value) =>
            FlLine(color: Colors.grey.withValues(alpha: 0.3), strokeWidth: 0.5),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: Colors.grey.withValues(alpha: 0.5)),
      ),
    );
  }
}
