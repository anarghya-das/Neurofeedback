import 'package:flutter/material.dart';
import 'package:lsl_flutter/lsl_flutter.dart';
import 'dart:developer' as developer;
import 'dart:async';

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

class _EEGViewerState extends State<EEGViewer> {
  InletWorker? _inletWorker;
  List<ResolvedStreamHandle> _availableStreams = [];
  String _statusText = 'Ready to search for streams';
  String _latestSample = 'No samples yet';
  bool _isStreaming = false;
  StreamSubscription? _sampleSubscription;
  String? _openInletId;

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
        _availableStreams = streams;
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

  Future<void> _connectToFirstStream() async {
    if (_inletWorker == null || _availableStreams.isEmpty) {
      setState(() {
        _statusText = 'No streams available to connect to';
      });
      return;
    }

    setState(() {
      _statusText = 'Connecting to stream...';
    });

    try {
      final firstStream = _availableStreams.first;
      final opened = await _inletWorker!.open(firstStream.id);

      if (opened) {
        _openInletId = firstStream.id;
        setState(() {
          _statusText = 'Connected to stream ID: ${firstStream.id}';
        });
        developer.log('Connected to stream ID: ${firstStream.id}');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Padding(
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
                    onPressed: _availableStreams.isNotEmpty
                        ? _connectToFirstStream
                        : null,
                    child: const Text('Connect to First Stream'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 16),
            if (_availableStreams.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Available Streams:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      ..._availableStreams.map(
                        (stream) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(
                            '• Stream ID: ${stream.id}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sampleSubscription?.cancel();
    super.dispose();
  }
}
