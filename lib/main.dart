import 'package:flutter/material.dart';
import 'package:lsl_flutter/lsl_flutter.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:developer' as developer;
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EEG Viewer LSL',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const EEGViewer(title: 'EEG Viewer - LSL Stream'),
    );
  }
}

class EEGViewer extends StatefulWidget {
  const EEGViewer({super.key, required this.title});

  final String title;

  @override
  State<EEGViewer> createState() => _EEGViewerState();
}

class StreamInfo {
  final ResolvedStreamHandle handle;
  final String name;
  final int channelCount;

  StreamInfo({
    required this.handle,
    required this.name,
    required this.channelCount,
  });

  String get id => handle.id;
}

class _EEGViewerState extends State<EEGViewer> {
  InletWorker? _inletWorker;
  List<StreamInfo> _availableStreams = [];
  String _statusText = 'Ready to search for streams';
  String _latestSample = 'No samples yet';
  bool _isStreaming = false;
  StreamSubscription? _sampleSubscription;
  String? _openInletId;
  int? _selectedStreamIndex; // Track which stream is selected

  // Time series data storage
  List<Queue<FlSpot>> _channelData = [];
  int _channelCount = 0;
  double _timeIndex = 0;
  final double _samplingRate = 250.0; // Default sampling rate

  // Chart display settings
  bool _showGraph = false;
  double _timeWindowSeconds = 4.0; // Show last 4 seconds
  double _amplitudeScale = 1.0;

  @override
  void initState() {
    super.initState();
    _initializeLSL();
  }

  void _initializeLSL() async {
    try {
      developer.log('Starting inlet worker...');
      _inletWorker = await InletWorker.spawn();
      setState(() {
        _statusText = 'LSL Inlet Worker initialized';
      });
      developer.log('LSL Inlet Worker initialized');
    } catch (e) {
      setState(() {
        _statusText = 'Error initializing LSL: $e';
      });
      developer.log('Error initializing LSL: $e');
    }
  }

  Future<void> _searchForStreams() async {
    if (_inletWorker == null) return;

    setState(() {
      _statusText = 'Searching for streams...';
    });

    try {
      final streams = await _inletWorker!.resolveStreams();
      setState(() {
        _availableStreams = streams.asMap().entries.map((entry) {
          int index = entry.key;
          ResolvedStreamHandle handle = entry.value;
          return StreamInfo(
            handle: handle,
            name: 'LSL Stream ${index + 1}', // More descriptive naming
            channelCount: 0, // Will be determined after connection
          );
        }).toList();
        _selectedStreamIndex = null; // Reset selection
        _statusText = 'Found ${_availableStreams.length} stream(s)';
      });

      for (int i = 0; i < _availableStreams.length; i++) {
        final stream = _availableStreams[i];
        developer.log('Stream $i: ID ${stream.id}');
      }
    } catch (e) {
      setState(() {
        _statusText = 'Error searching for streams: $e';
      });
      developer.log('Error searching for streams: $e');
    }
  }

  Future<void> _connectToSelectedStream() async {
    if (_inletWorker == null ||
        _availableStreams.isEmpty ||
        _selectedStreamIndex == null ||
        _selectedStreamIndex! >= _availableStreams.length) {
      setState(() {
        _statusText = 'No valid stream selected to connect to';
      });
      return;
    }

    setState(() {
      _statusText = 'Connecting to stream...';
    });

    try {
      final selectedStream = _availableStreams[_selectedStreamIndex!];
      final opened = await _inletWorker!.open(selectedStream.handle.id);

      if (opened) {
        _openInletId = selectedStream.id;
        setState(() {
          _statusText =
              'Connected to ${selectedStream.name} (ID: ${selectedStream.id})';
        });
        developer.log('Connected to stream ID: ${selectedStream.id}');
      } else {
        setState(() {
          _statusText = 'Failed to connect to stream';
        });
      }
    } catch (e) {
      setState(() {
        _statusText = 'Error connecting to stream: $e';
      });
      developer.log('Error connecting to stream: $e');
    }
  }

  Future<void> _startStreaming() async {
    if (_inletWorker == null || _openInletId == null) {
      setState(() {
        _statusText = 'No stream connected';
      });
      return;
    }

    try {
      final stream = await _inletWorker!.startSampleStream(
        _openInletId!,
        onCancel: () {
          developer.log('Sample stream cancelled');
        },
      );

      _sampleSubscription = stream.listen((sample) {
        _processSampleData(sample.$1, sample.$2);
        setState(() {
          _latestSample = 'Sample: ${sample.$1}\nTimestamp: ${sample.$2}';
        });
        developer.log('Sample: ${sample.$1}, Timestamp: ${sample.$2}');
      });

      setState(() {
        _isStreaming = true;
        _statusText = 'Streaming data...';
      });
    } catch (e) {
      setState(() {
        _statusText = 'Error starting stream: $e';
      });
      developer.log('Error starting stream: $e');
    }
  }

  void _stopStreaming() {
    setState(() {
      _isStreaming = false;
      _statusText = 'Stopped streaming';
    });
    _sampleSubscription?.cancel();
  }

  void _processSampleData(List<dynamic> sampleData, double timestamp) {
    if (sampleData.isEmpty) return;

    // Initialize channel data structures if needed
    if (_channelData.isEmpty || _channelData.length != sampleData.length) {
      _channelCount = sampleData.length;
      _channelData = List.generate(_channelCount, (index) => Queue<FlSpot>());
      _showGraph = true;
    }

    // Add new data points for each channel
    for (int i = 0; i < _channelCount && i < sampleData.length; i++) {
      double value = 0.0;
      try {
        value = double.parse(sampleData[i].toString());
      } catch (e) {
        // Handle non-numeric data
        value = 0.0;
      }

      // Add new point
      _channelData[i].add(FlSpot(_timeIndex, value));

      // Remove old points to maintain window size
      int maxPoints = (_timeWindowSeconds * _samplingRate).round();
      while (_channelData[i].length > maxPoints) {
        _channelData[i].removeFirst();
      }
    }

    _timeIndex += 1.0 / _samplingRate;
  }

  Widget _buildGraphView() {
    if (!_showGraph || _channelData.isEmpty) {
      return const Center(child: Text('No graph data available'));
    }

    return Column(
      children: [
        // Controls
        Row(
          children: [
            const Text('Time Window (s):'),
            Slider(
              value: _timeWindowSeconds,
              min: 1.0,
              max: 10.0,
              divisions: 18,
              label: _timeWindowSeconds.toStringAsFixed(1),
              onChanged: (value) {
                setState(() {
                  _timeWindowSeconds = value;
                });
              },
            ),
            const SizedBox(width: 20),
            const Text('Scale:'),
            Slider(
              value: _amplitudeScale,
              min: 0.1,
              max: 5.0,
              divisions: 49,
              label: _amplitudeScale.toStringAsFixed(1),
              onChanged: (value) {
                setState(() {
                  _amplitudeScale = value;
                });
              },
            ),
          ],
        ),
        // Graphs
        Expanded(
          child: ListView.builder(
            itemCount: _channelCount,
            itemBuilder: (context, channelIndex) {
              return Card(
                margin: const EdgeInsets.symmetric(
                  vertical: 4.0,
                  horizontal: 8.0,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Channel ${channelIndex + 1}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(
                        height: 150,
                        child: _channelData[channelIndex].isNotEmpty
                            ? LineChart(_buildLineChartData(channelIndex))
                            : const Center(child: Text('No data')),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  LineChartData _buildLineChartData(int channelIndex) {
    if (channelIndex >= _channelData.length ||
        _channelData[channelIndex].isEmpty) {
      return LineChartData(lineBarsData: []);
    }

    List<FlSpot> spots = _channelData[channelIndex].toList();

    // Calculate Y-axis range
    double minY =
        spots.map((spot) => spot.y).reduce(math.min) * _amplitudeScale;
    double maxY =
        spots.map((spot) => spot.y).reduce(math.max) * _amplitudeScale;
    double range = maxY - minY;
    if (range == 0) range = 1.0;

    // Adjust Y values by scale
    List<FlSpot> scaledSpots = spots
        .map((spot) => FlSpot(spot.x, spot.y * _amplitudeScale))
        .toList();

    return LineChartData(
      lineBarsData: [
        LineChartBarData(
          spots: scaledSpots,
          isCurved: false,
          color: _getChannelColor(channelIndex),
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
        ),
      ],
      minX: spots.isNotEmpty ? spots.last.x - _timeWindowSeconds : 0,
      maxX: spots.isNotEmpty ? spots.last.x : _timeWindowSeconds,
      minY: minY - range * 0.1,
      maxY: maxY + range * 0.1,
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (value, meta) {
              return Text(
                '${(value % 60).toStringAsFixed(1)}s',
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
                value.toStringAsFixed(1),
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

  Color _getChannelColor(int channelIndex) {
    final colors = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
    ];
    return colors[channelIndex % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: Text(widget.title),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.data_usage), text: 'Data'),
              Tab(icon: Icon(Icons.show_chart), text: 'Graphs'),
            ],
          ),
        ),
        body: TabBarView(children: [_buildDataView(), _buildGraphView()]),
      ),
    );
  }

  Widget _buildDataView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Status:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(_statusText),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _searchForStreams,
                  child: const Text('Search for Streams'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _selectedStreamIndex != null
                      ? _connectToSelectedStream
                      : null,
                  child: const Text('Connect to Selected'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Stream selection area
          if (_availableStreams.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Available Streams (Select one):',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 200,
                      child: ListView.builder(
                        itemCount: _availableStreams.length,
                        itemBuilder: (context, index) {
                          final stream = _availableStreams[index];
                          final isSelected = _selectedStreamIndex == index;

                          return Card(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primaryContainer
                                : null,
                            child: ListTile(
                              selected: isSelected,
                              onTap: () {
                                setState(() {
                                  _selectedStreamIndex = index;
                                });
                              },
                              leading: Icon(
                                isSelected
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              title: Text(stream.name),
                              subtitle: Text('ID: ${stream.id}'),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _openInletId != null && !_isStreaming
                      ? _startStreaming
                      : null,
                  child: const Text('Start Streaming'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: _isStreaming ? _stopStreaming : null,
                  child: const Text('Stop Streaming'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Latest Sample:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Text(
                          _latestSample,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sampleSubscription?.cancel();
    super.dispose();
  }
}
