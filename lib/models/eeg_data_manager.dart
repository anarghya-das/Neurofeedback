import 'dart:collection';
import 'package:fl_chart/fl_chart.dart';

class EEGDataManager {
  List<Queue<FlSpot>> _channelData = [];
  int _channelCount = 0;

  double _timeIndex = 0;
  double? _startTimestamp;

  double _samplingRate;
  final double maxTimeWindow;

  EEGDataManager({double samplingRate = 250.0, this.maxTimeWindow = 10.0})
      : _samplingRate = samplingRate;

  double get samplingRate => _samplingRate;
  double get currentTimeSeconds => _timeIndex;
  int get channelCount => _channelCount;

  void updateSamplingRate(double newSamplingRate) {
    if (newSamplingRate > 0) {
      _samplingRate = newSamplingRate;
    }
  }

  Queue<FlSpot> getChannelData(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= _channelData.length) {
      return Queue<FlSpot>();
    }
    return _channelData[channelIndex];
  }

  List<Queue<FlSpot>> get allChannelData => _channelData;

  void processSample(List<dynamic> sampleData, double timestamp) {
    if (sampleData.isEmpty) return;

    if (_channelData.isEmpty || _channelData.length != sampleData.length) {
      _channelCount = sampleData.length;
      _channelData = List.generate(_channelCount, (_) => Queue<FlSpot>());
    }

    _startTimestamp ??= timestamp;
    final plotTime = timestamp - _startTimestamp!;
    _timeIndex = plotTime;

    for (int i = 0; i < _channelCount && i < sampleData.length; i++) {
      final value = _parseValue(sampleData[i]);
      _channelData[i].add(FlSpot(plotTime, value));
      _maintainWindowSize(i);
    }
  }

  double _parseValue(dynamic value) {
    try {
      return double.parse(value.toString());
    } catch (_) {
      return 0.0;
    }
  }

  void _maintainWindowSize(int channelIndex) {
    final maxPoints = (maxTimeWindow * _samplingRate).round();
    while (_channelData[channelIndex].length > maxPoints) {
      _channelData[channelIndex].removeFirst();
    }
  }

  void clear() {
    _channelData.clear();
    _channelCount = 0;
    _timeIndex = 0;
    _startTimestamp = null;
  }

  bool get hasData =>
      _channelData.isNotEmpty && _channelData.any((q) => q.isNotEmpty);
}