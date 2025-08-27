import 'package:lsl_flutter/lsl_flutter.dart';

/// Represents information about an LSL stream
class StreamInfo {
  final ResolvedStreamHandle handle;
  final String name;
  final int channelCount;

  StreamInfo({
    required this.handle,
    required this.name,
    required this.channelCount,
  });

  /// Get the stream ID from the handle
  String get id => handle.id;

  @override
  String toString() {
    return 'StreamInfo(name: $name, id: $id, channels: $channelCount)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamInfo && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
