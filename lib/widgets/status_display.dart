import 'package:flutter/material.dart';

/// Widget for displaying connection and streaming status
class StatusDisplay extends StatelessWidget {
  final String statusText;

  const StatusDisplay({super.key, required this.statusText});

  @override
  Widget build(BuildContext context) {
    return Card(
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
            Text(statusText),
          ],
        ),
      ),
    );
  }
}
