import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:developer' as developer;
import '../models/stream_info.dart';
import '../models/eeg_data_manager.dart';
import '../services/lsl_service.dart';
import '../screens/data_view_screen.dart';
import '../screens/graph_view_screen.dart';

/// Main EEG viewer widget with tabbed interface
class EEGViewer extends StatefulWidget {
  const EEGViewer({super.key, required this.title});

  final String title;

  @override
  State<EEGViewer> createState() => _EEGViewerState();
}

class _EEGViewerState extends State<EEGViewer> {
  // Services and data management
  final LSLService _lslService = LSLService();
  final EEGDataManager _dataManager = EEGDataManager();

  // State variables
  List<StreamInfo> _availableStreams = [];
  String _statusText = 'Ready to search for streams';
  String _latestSample = 'No samples yet';
  int? _selectedStreamIndex;
  StreamSubscription? _sampleSubscription;

  // Chart display settings
  double _timeWindowSeconds = 4.0;
  double _amplitudeScale = 1.0;

  @override
  void initState() {
    super.initState();
    _initializeLSL();
  }

  @override
  void dispose() {
    _sampleSubscription?.cancel();
    _lslService.dispose();
    super.dispose();
  }

  Future<void> _initializeLSL() async {
    try {
      await _lslService.initialize();
      setState(() {
        _statusText = 'LSL service initialized';
      });
    } catch (e) {
      setState(() {
        _statusText = 'Error initializing LSL: $e';
      });
    }
  }

  Future<void> _searchForStreams() async {
    try {
      setState(() {
        _statusText = 'Searching for streams...';
      });

      final streams = await _lslService.searchStreams();
      setState(() {
        _availableStreams = streams;
        _selectedStreamIndex = null;
        _statusText = 'Found ${_availableStreams.length} stream(s)';
      });
    } catch (e) {
      setState(() {
        _statusText = 'Error searching for streams: $e';
      });
    }
  }

  Future<void> _connectToSelectedStream() async {
    if (_selectedStreamIndex == null ||
        _selectedStreamIndex! >= _availableStreams.length) {
      setState(() {
        _statusText = 'No valid stream selected to connect to';
      });
      return;
    }

    try {
      setState(() {
        _statusText = 'Connecting to stream...';
      });

      final selectedStream = _availableStreams[_selectedStreamIndex!];
      final connected = await _lslService.connectToStream(selectedStream);

      if (connected) {
        setState(() {
          _statusText =
              'Connected to ${selectedStream.name} (ID: ${selectedStream.id})';
        });
      } else {
        setState(() {
          _statusText = 'Failed to connect to stream';
        });
      }
    } catch (e) {
      setState(() {
        _statusText = 'Error connecting to stream: $e';
      });
    }
  }

  Future<void> _startStreaming() async {
    try {
      final stream = await _lslService.startStreaming();

      _sampleSubscription = stream.listen((sample) {
        _dataManager.processSample(sample.$1, sample.$2);
        setState(() {
          _latestSample = 'Sample: ${sample.$1}\nTimestamp: ${sample.$2}';
        });
      });

      setState(() {
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
    _lslService.stopStreaming();
    _sampleSubscription?.cancel();
    setState(() {
      _statusText = 'Stopped streaming';
    });
  }

  void _onStreamSelected(int index) {
    setState(() {
      _selectedStreamIndex = index;
    });
  }

  void _onTimeWindowChanged(double value) {
    setState(() {
      _timeWindowSeconds = value;
    });
  }

  void _onAmplitudeScaleChanged(double value) {
    setState(() {
      _amplitudeScale = value;
    });
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
        body: TabBarView(
          children: [
            DataViewScreen(
              statusText: _statusText,
              latestSample: _latestSample,
              availableStreams: _availableStreams,
              selectedStreamIndex: _selectedStreamIndex,
              isStreaming: _lslService.isStreaming,
              openInletId: _lslService.openInletId,
              onSearchStreams: _searchForStreams,
              onConnectToSelected: _selectedStreamIndex != null
                  ? _connectToSelectedStream
                  : null,
              onStreamSelected: _onStreamSelected,
              onStartStreaming:
                  _lslService.openInletId != null && !_lslService.isStreaming
                  ? _startStreaming
                  : null,
              onStopStreaming: _lslService.isStreaming ? _stopStreaming : null,
            ),
            GraphViewScreen(
              dataManager: _dataManager,
              timeWindowSeconds: _timeWindowSeconds,
              amplitudeScale: _amplitudeScale,
              onTimeWindowChanged: _onTimeWindowChanged,
              onAmplitudeScaleChanged: _onAmplitudeScaleChanged,
            ),
          ],
        ),
      ),
    );
  }
}
