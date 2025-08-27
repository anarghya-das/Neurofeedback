import 'package:flutter/material.dart';
import '../models/stream_info.dart';

/// Widget for selecting LSL streams
class StreamSelector extends StatelessWidget {
  final List<StreamInfo> availableStreams;
  final int? selectedStreamIndex;
  final Function(int) onStreamSelected;

  const StreamSelector({
    super.key,
    required this.availableStreams,
    required this.selectedStreamIndex,
    required this.onStreamSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (availableStreams.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
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
                itemCount: availableStreams.length,
                itemBuilder: (context, index) {
                  final stream = availableStreams[index];
                  final isSelected = selectedStreamIndex == index;

                  return Card(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                    child: ListTile(
                      selected: isSelected,
                      onTap: () => onStreamSelected(index),
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(stream.name),
                      subtitle: Text(
                        'ID: ${stream.id} • Channels: ${stream.channelCount} • ${stream.nominalSampleRate}Hz • ${stream.type}',
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
