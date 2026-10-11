import 'package:flutter/material.dart';

import '../eeg_filters.dart';
import '../headset.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);

/// Switches for the live stream's filters. Changes apply immediately, also
/// while streaming.
class FilterSettingsPanel extends StatelessWidget {
  const FilterSettingsPanel({super.key, required this.headset});

  final Mw75Headset headset;

  static String _hz(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: headset,
      builder: (context, _) {
        final f = headset.filters;
        void set(EegFilterSettings value) => headset.filters = value;
        Widget toggle(String title, String subtitle, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _ink)),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 11, color: _muted, height: 1.3)),
          value: value,
          onChanged: onChanged,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              f.applyToLsl
                  ? 'Applied to the live plot, band power and the LSL stream.'
                  : 'Applied to the live plot and band power. The LSL stream carries the EEG as measured.',
              style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
            const SizedBox(height: 4),
            toggle(
              '${_hz(EegFilterSettings.highPassHz)} Hz high-pass',
              "Removes the electrodes' slow drift (Research Kit's DC offset option).",
              f.highPass,
              (v) => set(f.copyWith(highPass: v)),
            ),
            toggle(
              'Mains notch',
              'Removes ${_hz(f.mainsHz)} Hz power-line noise and its ${_hz(2 * f.mainsHz)} Hz harmonic. '
              '60 Hz in the Americas, 50 Hz in most other places.',
              f.notch,
              (v) => set(f.copyWith(notch: v)),
            ),
            if (f.notch)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SegmentedButton<double>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                  ),
                  segments: [
                    for (final hz in EegFilterSettings.mainsOptions)
                      ButtonSegment(value: hz, label: Text('${_hz(hz)} Hz')),
                  ],
                  selected: {f.mainsHz},
                  onSelectionChanged: (v) => set(f.copyWith(mainsHz: v.first)),
                ),
              ),
            toggle(
              'Band-pass',
              'Keeps only the band below; Butterworth, applied live.',
              f.bandPass,
              (v) => set(f.copyWith(bandPass: v)),
            ),
            if (f.bandPass)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: _HzDropdown(
                        value: f.bandLow,
                        options: EegFilterSettings.bandLowOptions.where((v) => v < f.bandHigh).toList(),
                        onChanged: (v) => set(f.copyWith(bandLow: v)),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('to', style: TextStyle(fontSize: 12, color: _muted)),
                    ),
                    Expanded(
                      child: _HzDropdown(
                        value: f.bandHigh,
                        options: EegFilterSettings.bandHighOptions.where((v) => v > f.bandLow).toList(),
                        onChanged: (v) => set(f.copyWith(bandHigh: v)),
                      ),
                    ),
                  ],
                ),
              ),
            toggle(
              'Filter the LSL stream too',
              'Off: LSL carries the EEG as measured and only this app\'s plots are filtered.',
              f.applyToLsl,
              (v) => set(f.copyWith(applyToLsl: v)),
            ),
            const SizedBox(height: 4),
            const Text(
              'The oddball and alpha tests always use the unfiltered EEG with their own filters, and save it '
              'unfiltered, so their results do not depend on these switches.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
          ],
        );
      },
    );
  }
}

class _HzDropdown extends StatelessWidget {
  const _HzDropdown({required this.value, required this.options, required this.onChanged});

  final double value;
  final List<double> options;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: _line),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<double>(
        isExpanded: true,
        value: value,
        style: const TextStyle(fontSize: 12, color: _ink),
        items: [
          for (final v in options)
            DropdownMenuItem(value: v, child: Text('${FilterSettingsPanel._hz(v)} Hz')),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    ),
  );
}
