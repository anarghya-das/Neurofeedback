import 'package:flutter/material.dart';

/// Utility functions for chart styling and colors
class ChartUtils {
  /// Get a color for a specific channel
  static Color getChannelColor(int channelIndex) {
    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
      Colors.amber,
      Colors.deepOrange,
      Colors.lightGreen,
    ];
    return colors[channelIndex % colors.length];
  }

  /// Format time value for display
  static String formatTime(double timeValue) {
    return '${(timeValue % 60).toStringAsFixed(1)}s';
  }

  /// Format amplitude value for display
  static String formatAmplitude(double value) {
    return value.toStringAsFixed(1);
  }
}
