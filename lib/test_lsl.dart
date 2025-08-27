import 'package:lsl_flutter/lsl_flutter.dart';
import 'dart:developer' as developer;

void main() async {
  try {
    developer.log('Creating StreamManager...');
    final streamManager = StreamManager();
    developer.log('StreamManager created successfully');

    developer.log('Attempting to resolve streams with timeout 5.0...');
    try {
      streamManager.resolveStreams(5.0);
      developer.log('resolveStreams(5.0) called successfully');
    } catch (e) {
      developer.log('resolveStreams(5.0) error: $e');
    }
  } catch (e) {
    developer.log('Main error: $e');
  }
}
