import 'package:lsl_flutter/lsl_flutter.dart';

/// Represents information about an LSL stream
class StreamInfo {
  final ResolvedStreamHandle handle;
  final String _name;
  final int _channelCount;
  final double _nominalSampleRate;
  final String _type;

  StreamInfo({
    required this.handle,
    String? name,
    int? channelCount,
    double? nominalSampleRate,
    String? type,
  }) : _name = name ?? 'LSL Stream',
       _channelCount = channelCount ?? 0,
       _nominalSampleRate = nominalSampleRate ?? 0.0,
       _type = type ?? 'Unknown';

  /// Factory constructor to create StreamInfo from ResolvedStreamHandle
  /// This extracts metadata from the handle's info property
  factory StreamInfo.fromHandle(ResolvedStreamHandle handle, {int index = 0}) {
    String name = 'LSL Stream ${index + 1}';
    int channelCount = 0;
    double nominalSampleRate = 0.0;
    String type = 'Unknown';

    // Access stream metadata from the handle's info property
    try {
      final lslInfo = handle.info;
      name = lslInfo.name.isNotEmpty ? lslInfo.name : 'LSL Stream ${index + 1}';
      channelCount = lslInfo.channelCount;
      nominalSampleRate = lslInfo.nominalSRate;
      type = lslInfo.type.isNotEmpty ? lslInfo.type : 'Unknown';
    } catch (e) {
      // If we can't access the metadata, use defaults with better naming
      name = 'LSL Stream ${index + 1}';
    }

    return StreamInfo(
      handle: handle,
      name: name,
      channelCount: channelCount,
      nominalSampleRate: nominalSampleRate,
      type: type,
    );
  }

  /// Get the stream ID from the handle
  String get id => handle.id;

  /// Get the stream name
  String get name => _name;

  /// Get the channel count
  int get channelCount => _channelCount;

  /// Get the nominal sampling rate
  double get nominalSampleRate => _nominalSampleRate;

  /// Get the stream type
  String get type => _type;

  /// Create a copy with updated metadata
  StreamInfo copyWith({
    String? name,
    int? channelCount,
    double? nominalSampleRate,
    String? type,
  }) {
    return StreamInfo(
      handle: handle,
      name: name ?? _name,
      channelCount: channelCount ?? _channelCount,
      nominalSampleRate: nominalSampleRate ?? _nominalSampleRate,
      type: type ?? _type,
    );
  }

  @override
  String toString() {
    return 'StreamInfo(name: "$name", id: $id, channels: $channelCount, rate: ${nominalSampleRate}Hz, type: "$type")';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamInfo && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
