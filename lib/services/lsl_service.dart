import 'dart:async';
import 'dart:developer' as developer;
import 'package:lsl_flutter/lsl_flutter.dart' hide StreamInfo;
import '../models/stream_info.dart';

/// Service for managing LSL (Lab Streaming Layer) connections and data streaming
class LSLService {
  InletWorker? _inletWorker;
  String? _openInletId;
  StreamSubscription? _sampleSubscription;
  bool _isInitialized = false;
  bool _isStreaming = false;

  /// Get initialization status
  bool get isInitialized => _isInitialized;

  /// Get streaming status
  bool get isStreaming => _isStreaming;

  /// Get connected inlet ID
  String? get openInletId => _openInletId;

  /// Initialize the LSL service
  Future<void> initialize() async {
    try {
      developer.log('Starting LSL inlet worker...');
      _inletWorker = await InletWorker.spawn();
      _isInitialized = true;
      developer.log('LSL Inlet Worker initialized successfully');
    } catch (e) {
      _isInitialized = false;
      developer.log('Error initializing LSL: $e');
      rethrow;
    }
  }

  /// Search for available LSL streams
  Future<List<StreamInfo>> searchStreams() async {
    if (!_isInitialized || _inletWorker == null) {
      throw Exception('LSL service not initialized');
    }

    try {
      developer.log('Searching for LSL streams...');
      final streams = await _inletWorker!.resolveStreams();

      final streamInfoList = streams.asMap().entries.map((entry) {
        int index = entry.key;
        ResolvedStreamHandle handle = entry.value;

        return StreamInfo.fromHandle(handle, index: index);
      }).toList();

      developer.log('Found ${streamInfoList.length} stream(s)');
      for (int i = 0; i < streamInfoList.length; i++) {
        developer.log('Stream $i: ${streamInfoList[i]}');
      }

      return streamInfoList;
    } catch (e) {
      developer.log('Error searching for streams: $e');
      rethrow;
    }
  }

  /// Connect to a specific stream
  Future<bool> connectToStream(StreamInfo streamInfo) async {
    if (!_isInitialized || _inletWorker == null) {
      throw Exception('LSL service not initialized');
    }

    try {
      developer.log('Connecting to stream: ${streamInfo.id}');
      final opened = await _inletWorker!.open(streamInfo.handle.id);

      if (opened) {
        _openInletId = streamInfo.id;
        developer.log('Successfully connected to stream: ${streamInfo.id}');
        return true;
      } else {
        developer.log('Failed to connect to stream: ${streamInfo.id}');
        return false;
      }
    } catch (e) {
      developer.log('Error connecting to stream: $e');
      rethrow;
    }
  }

  /// Start streaming data from the connected inlet
  Future<Stream<(List<dynamic>, double)>> startStreaming() async {
    if (!_isInitialized || _inletWorker == null || _openInletId == null) {
      throw Exception('No stream connected or LSL not initialized');
    }

    try {
      developer.log('Starting sample stream for inlet: $_openInletId');
      final stream = await _inletWorker!.startSampleStream(
        _openInletId!,
        onCancel: () {
          developer.log('Sample stream cancelled');
          _isStreaming = false;
        },
      );

      _isStreaming = true;
      developer.log('Sample stream started successfully');
      return stream;
    } catch (e) {
      developer.log('Error starting stream: $e');
      rethrow;
    }
  }

  /// Get enhanced stream metadata after connection
  /// This attempts to get additional stream information that may not be available before connection
  Future<StreamInfo?> getStreamMetadata(StreamInfo streamInfo) async {
    if (!_isInitialized || _inletWorker == null) {
      return null;
    }

    try {
      // For now, we'll just return the existing stream info
      // In the future, this could be enhanced to get more detailed metadata
      // from the connected inlet
      developer.log('Getting metadata for stream: ${streamInfo.id}');
      return streamInfo;
    } catch (e) {
      developer.log('Error getting stream metadata: $e');
      return null;
    }
  }

  /// Stop streaming data
  void stopStreaming() {
    if (_sampleSubscription != null) {
      _sampleSubscription!.cancel();
      _sampleSubscription = null;
    }
    _isStreaming = false;
    developer.log('Streaming stopped');
  }

  /// Disconnect from the current stream
  void disconnect() {
    stopStreaming();
    _openInletId = null;
    developer.log('Disconnected from stream');
  }

  /// Dispose of the LSL service and clean up resources
  void dispose() {
    stopStreaming();
    _openInletId = null;
    _inletWorker = null;
    _isInitialized = false;
    developer.log('LSL service disposed');
  }
}
