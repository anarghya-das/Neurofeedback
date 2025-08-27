import 'package:flutter/material.dart';
import '../models/stream_info.dart';
import '../widgets/status_display.dart';
import '../widgets/stream_selector.dart';

/// Screen for data view and stream management
class DataViewScreen extends StatelessWidget {
  final String statusText;
  final String latestSample;
  final List<StreamInfo> availableStreams;
  final int? selectedStreamIndex;
  final bool isStreaming;
  final String? openInletId;
  final VoidCallback onSearchStreams;
  final Function(int) onStreamSelected;
  final VoidCallback? onStartStreaming;
  final VoidCallback? onStopStreaming;

  const DataViewScreen({
    super.key,
    required this.statusText,
    required this.latestSample,
    required this.availableStreams,
    required this.selectedStreamIndex,
    required this.isStreaming,
    required this.openInletId,
    required this.onSearchStreams,
    required this.onStreamSelected,
    required this.onStartStreaming,
    required this.onStopStreaming,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          StatusDisplay(statusText: statusText),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onSearchStreams,
            child: const Text('Search for Streams'),
          ),
          const SizedBox(height: 16),
          StreamSelector(
            availableStreams: availableStreams,
            selectedStreamIndex: selectedStreamIndex,
            onStreamSelected: onStreamSelected,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onStartStreaming,
                  child: const Text('Start Streaming'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: onStopStreaming,
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
                          latestSample,
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
}
