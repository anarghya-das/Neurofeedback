import 'dart:developer' as developer;
import 'package:lsl_flutter/lsl_flutter.dart';

class LSLMarkerService {
  static const String streamName = 'AudioMarkers';
  static const String streamType = 'Markers';

  OutletWorker? _worker;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized && _worker != null) {
      print('AudioMarkers already initialized');
      developer.log('AudioMarkers already initialized');
      return;
    }

    try {
      print('Starting AudioMarkers outlet worker...');
      developer.log('Starting AudioMarkers outlet worker...');

      _worker = await OutletWorker.spawn();

      final streamInfo = StreamInfoFactory.createStringStreamInfo(
        streamName,
        streamType,
        const CftStringChannelFormat(),
        channelCount: 1,
        nominalSRate: 0,
        sourceId: 'audio-markers',
      );

      final ok = await _worker!.addStream(streamInfo);

      print('AudioMarkers addStream result: $ok');
      developer.log('AudioMarkers addStream result: $ok');

      if (!ok) {
        throw Exception('Failed to add AudioMarkers stream outlet');
      }

      _initialized = true;

      print('AudioMarkers LSL outlet initialized');
      developer.log('AudioMarkers LSL outlet initialized');
    } catch (e, st) {
      _initialized = false;
      _worker = null;

      print('FAILED to initialize AudioMarkers outlet: $e');
      developer.log(
        'Failed to initialize AudioMarkers outlet',
        error: e,
        stackTrace: st,
      );

      rethrow;
    }
  }

  Future<double> sendMarker(String value) async {
    print('sendMarker called with value=$value');
    developer.log('sendMarker called with value=$value');

    if (!_initialized || _worker == null) {
      print('AudioMarkers not initialized. Initializing now...');
      developer.log('AudioMarkers not initialized. Initializing now...');
      await initialize();
    }

    try {
      print('Pushing AudioMarkers sample: $value');
      developer.log('Pushing AudioMarkers sample: $value');

      // Timestamp right before pushing marker.
      // This is wall-clock seconds. Good enough for your session log column.
      final timestamp = DateTime.now().microsecondsSinceEpoch / 1000000.0;

      final ok = await _worker!.pushSample(streamName, <String>[value]);

      print('AudioMarkers pushSample result: $ok value=$value');
      developer.log('AudioMarkers pushSample result: $ok value=$value');

      if (!ok) {
        throw Exception('pushSample returned false for marker: $value');
      }

      print('AudioMarkers marker emitted: $value');
      developer.log('AudioMarkers marker emitted: $value');

      return timestamp;
    } catch (e, st) {
      print('FAILED to push AudioMarkers marker: $value error=$e');

      developer.log(
        'Failed to push AudioMarkers marker: $value',
        error: e,
        stackTrace: st,
      );

      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      if (_worker != null) {
        print('Disposing AudioMarkers outlet...');
        await _worker!.removeStream(streamName);
        _worker!.shutdown();
      }
    } catch (e, st) {
      print('Error disposing AudioMarkers outlet: $e');

      developer.log(
        'Error disposing AudioMarkers outlet',
        error: e,
        stackTrace: st,
      );
    } finally {
      _worker = null;
      _initialized = false;
    }
  }
}
