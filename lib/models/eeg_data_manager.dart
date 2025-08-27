import 'dart:collection';
import 'package:fl_chart/fl_chart.dart';

/// Manages EEG data for real-time visualization
class EEGDataManager {
  List<Queue<FlSpot>> _channelData = [];
  int _channelCount = 0;
  double _timeIndex = 0;
  double _samplingRate;
  final double maxTimeWindow;

  EEGDataManager({double samplingRate = 250.0, this.maxTimeWindow = 10.0})
    : _samplingRate = samplingRate;

  /// Get the current sampling rate
  double get samplingRate => _samplingRate;

  /// Update the sampling rate (useful when connecting to a new stream)
  void updateSamplingRate(double newSamplingRate) {
    if (newSamplingRate > 0) {
      _samplingRate = newSamplingRate;
    }
  }

  /// Get the number of channels
  int get channelCount => _channelCount;

  /// Get data for a specific channel
  Queue<FlSpot> getChannelData(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= _channelData.length) {
      return Queue<FlSpot>();
    }
    return _channelData[channelIndex];
  }

  /// Get all channel data
  List<Queue<FlSpot>> get allChannelData => _channelData;

  /// Process new sample data
  void processSample(List<dynamic> sampleData, double timestamp) {
    if (sampleData.isEmpty) return;

    // Initialize channel data structures if needed
    if (_channelData.isEmpty || _channelData.length != sampleData.length) {
      _channelCount = sampleData.length;
      _channelData = List.generate(_channelCount, (index) => Queue<FlSpot>());
    }

    // Add new data points for each channel
    for (int i = 0; i < _channelCount && i < sampleData.length; i++) {
      double value = _parseValue(sampleData[i]);

      // Add new point
      _channelData[i].add(FlSpot(_timeIndex, value));

      // Remove old points to maintain window size
      _maintainWindowSize(i);
    }

    _timeIndex += 1.0 / _samplingRate;
  }

  /// Parse value from sample data, handling non-numeric data
  double _parseValue(dynamic value) {
    try {
      return double.parse(value.toString());
    } catch (e) {
      return 0.0;
    }
  }

  /// Maintain the time window size for a channel
  void _maintainWindowSize(int channelIndex) {
    int maxPoints = (maxTimeWindow * _samplingRate).round();
    while (_channelData[channelIndex].length > maxPoints) {
      _channelData[channelIndex].removeFirst();
    }
  }

  /// Clear all data
  void clear() {
    _channelData.clear();
    _channelCount = 0;
    _timeIndex = 0;
  }

  /// Check if data is available
  bool get hasData =>
      _channelData.isNotEmpty && _channelData.any((queue) => queue.isNotEmpty);
}
