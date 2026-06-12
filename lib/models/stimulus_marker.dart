class StimulusMarker {
  final double graphTimeSeconds;
  final String type;
  final String label;
  final DateTime wallTime;

  const StimulusMarker({
    required this.graphTimeSeconds,
    required this.type,
    required this.label,
    required this.wallTime,
  });

  String get displayLabel {
    switch (type) {
      case 'AUDIO_START':
        return 'Start: $label';
      case 'AUDIO_STOP':
        return 'Stop: $label';
      case 'AUDIO_PAUSE':
        return 'Pause';
      case 'AUDIO_NEXT':
        return 'Next: $label';
      default:
        return label.isEmpty ? type : '$type: $label';
    }
  }
}