import 'package:flutter/material.dart';

import '../headset.dart';
import '../signal_quality.dart';
import 'ear_cup_map.dart';

/// Device picker, start/stop control and live contact-quality map for the MW75.
///
/// Meant to sit inside the dashboard's card; [HeadsetStatusBadge] goes in the
/// card's trailing slot.
class HeadsetPanel extends StatelessWidget {
  const HeadsetPanel({super.key, required this.headset, this.startBlockedReason});

  final Mw75Headset headset;

  /// When non-null the start button is disabled and this explains why (for
  /// example, the Focus session is using the headset).
  final String? startBlockedReason;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: headset,
      builder: (context, _) {
        final busy = headset.state == HeadsetState.starting || headset.state == HeadsetState.stopping;
        final streaming = headset.state == HeadsetState.streaming;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              headset.batteryPercent != null
                  ? 'Neurable MW75 Neuro, battery ${headset.batteryPercent}%'
                  : 'Neurable MW75 Neuro over Bluetooth',
              style: const TextStyle(fontSize: 12, color: Color(0xFF69707D)),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _DevicePicker(headset: headset, enabled: !busy && !streaming)),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Reload paired devices',
                  child: IconButton.outlined(
                    onPressed: busy || streaming ? null : headset.refreshDevices,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(36, 36),
                      side: const BorderSide(color: Color(0xFFD9DCE3)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 34,
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy
                    ? null
                    : streaming
                    ? headset.stop
                    : headset.selectedDevice == null || startBlockedReason != null
                    ? null
                    : headset.start,
                icon: busy
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6, color: Color(0xFF9CA3AF)),
                      )
                    : Icon(streaming ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 15),
                label: Text(
                  switch (headset.state) {
                    HeadsetState.starting => 'Starting…',
                    HeadsetState.stopping => 'Stopping…',
                    HeadsetState.streaming => 'Stop streaming',
                    _ => 'Start streaming',
                  },
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                ),
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  backgroundColor: const Color(0xFF080615),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFF2F2F5),
                  disabledForegroundColor: const Color(0xFF9CA3AF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              !streaming && !busy && startBlockedReason != null ? startBlockedReason! : headset.statusText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: headset.state == HeadsetState.error ? const Color(0xFFB42318) : const Color(0xFF69707D),
              ),
            ),
            if (headset.warning != null) ...[
              const SizedBox(height: 8),
              _Notice(text: headset.warning!),
            ],
            if (streaming) ...[
              const SizedBox(height: 10),
              _DataLoss(ratio: headset.recentLossRatio),
            ],
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Electrode contact',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111216)),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Adjust the headphones so the sensors touch the skin around your ears, then keep still.',
                        style: TextStyle(fontSize: 11, color: Color(0xFF69707D), height: 1.35),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                StrictnessPicker(
                  value: headset.qualityStrictness,
                  onChanged: (v) => headset.qualityStrictness = v,
                ),
              ],
            ),
            const SizedBox(height: 12),
            EarCupQualityMap(
              quality: streaming ? headset.quality : null,
              strictness: headset.qualityStrictness,
            ),
            const SizedBox(height: 10),
            Text(
              _summary(streaming ? headset.quality : null),
              style: const TextStyle(fontSize: 11, color: Color(0xFF69707D), height: 1.35),
            ),
          ],
        );
      },
    );
  }

  static String _summary(Mw75SignalQuality? q) {
    if (q == null) return 'Contact quality updates every second while the headset streams.';
    if (q.ref == ContactQuality.bad) {
      return 'Reference contact is poor, so every channel is unreliable. Reseat the headset.';
    }
    final bad = [
      for (var i = 0; i < q.channels.length; i++)
        if (q.channels[i] == ContactQuality.bad) 'Ch${i + 1}',
    ];
    if (bad.isEmpty) return 'All electrodes are making usable contact.';
    if (bad.length == 1) return 'Poor contact on ${bad.single}.';
    return 'Poor contact on ${bad.sublist(0, bad.length - 1).join(', ')} and ${bad.last}.';
  }
}

/// Status pill for the card header.
class HeadsetStatusBadge extends StatelessWidget {
  const HeadsetStatusBadge({super.key, required this.headset});

  final Mw75Headset headset;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: headset,
      builder: (context, _) {
        final active = headset.state == HeadsetState.streaming;
        final text = switch (headset.state) {
          HeadsetState.idle => 'Not streaming',
          HeadsetState.starting => 'Starting',
          HeadsetState.streaming => 'Streaming',
          HeadsetState.stopping => 'Stopping',
          HeadsetState.error => 'Error',
        };
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE8F8EF) : const Color(0xFFF1F1F4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? const Color(0xFFB7E4C7) : const Color(0xFFD9DCE3)),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: active ? const Color(0xFF0F7A3C) : const Color(0xFF404651),
            ),
          ),
        );
      },
    );
  }
}

class _DevicePicker extends StatelessWidget {
  const _DevicePicker({required this.headset, required this.enabled});

  final Mw75Headset headset;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final devices = headset.devices;
    final selected = headset.selectedDevice;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: enabled ? Colors.white : const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: const Color(0xFFD9DCE3)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: selected?.address,
          hint: Text(
            devices.isEmpty ? 'No paired headset found' : 'Choose a paired headset',
            style: const TextStyle(fontSize: 12, color: Color(0xFF69707D)),
          ),
          style: const TextStyle(fontSize: 12, color: Color(0xFF111216)),
          items: [
            for (final d in devices)
              DropdownMenuItem(
                value: d.address,
                child: Text(
                  d.name.isEmpty ? d.address : d.name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled
              ? (address) {
                  final match = devices.where((d) => d.address == address);
                  if (match.isNotEmpty) headset.selectDevice(match.first);
                }
              : null,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF7E6),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0xFFF3D9A4)),
    ),
    child: Text(text, style: const TextStyle(fontSize: 11, color: Color(0xFF7A4B00), height: 1.35)),
  );
}

/// Share of EEG lost over Bluetooth in the last 10 s. Lost samples are filled
/// in and flagged in the stream's sampleStatus channel; above 25% the panel
/// says so, because that much reconstructed data affects analysis.
class _DataLoss extends StatelessWidget {
  const _DataLoss({required this.ratio});

  final double? ratio;

  static const _warnAbove = 0.25;

  @override
  Widget build(BuildContext context) {
    final r = ratio;
    final high = r != null && r > _warnAbove;
    final percent = r == null ? null : (r * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Data lost over Bluetooth (last 10 s)', style: TextStyle(fontSize: 11, color: Color(0xFF69707D))),
            ),
            Text(
              percent == null ? 'measuring…' : '$percent%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: high ? const Color(0xFFB42318) : const Color(0xFF111216),
              ),
            ),
          ],
        ),
        if (high) ...[
          const SizedBox(height: 6),
          _Notice(
            text:
                '$percent% of the EEG in the last 10 s was lost and filled in. Those samples are '
                'flagged in the stream. Audio playing through the headset makes this worse.',
          ),
        ],
      ],
    );
  }
}
