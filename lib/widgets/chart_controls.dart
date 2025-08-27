import 'package:flutter/material.dart';

/// Widget for chart display controls (dropdown style)
class ChartControls extends StatelessWidget {
  final double timeWindowSeconds; // 1,2,5,10
  final double amplitudeScale; // legacy: treat as full-scale µV
  final Function(double) onTimeWindowChanged;
  final Function(double) onAmplitudeScaleChanged; // legacy setter

  const ChartControls({
    super.key,
    required this.timeWindowSeconds,
    required this.amplitudeScale,
    required this.onTimeWindowChanged,
    required this.onAmplitudeScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    final windowOptions = const [1.0, 2.0, 5.0, 10.0];
    final scaleOptions = const [50.0, 100.0, 200.0, 400.0];

    // Interpret amplitudeScale as full-scale µV if it looks like one
    final fullScale = (amplitudeScale >= 20 && amplitudeScale <= 1000)
        ? amplitudeScale
        : 200.0;

    return Container(
      color: Colors.grey.shade400,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Text(
            'Vert Scale',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xFF0E2433),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 110,
            child: _DropdownBox<double>(
              value: fullScale,
              items: scaleOptions,
              itemLabel: (v) => '${v.toStringAsFixed(0)} uV',
              onChanged: (v) => onAmplitudeScaleChanged(v),
            ),
          ),
          const SizedBox(width: 24),
          const Text(
            'Window',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xFF0E2433),
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 110,
            child: _DropdownBox<double>(
              value: windowOptions.contains(timeWindowSeconds)
                  ? timeWindowSeconds
                  : 5.0,
              items: windowOptions,
              itemLabel: (v) => '${v.toStringAsFixed(0)} sec',
              onChanged: onTimeWindowChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _DropdownBox<T extends num> extends StatelessWidget {
  final T value;
  final List<T> items;
  final String Function(T) itemLabel;
  final Function(T) onChanged;

  const _DropdownBox({
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black54),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isDense: true,
          value: value,
          items: [
            for (final v in items)
              DropdownMenuItem<T>(
                value: v,
                child: Text(
                  itemLabel(v),
                  style: const TextStyle(color: Color(0xFF0E2433)),
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
