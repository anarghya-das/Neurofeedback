import 'package:flutter/material.dart';

/// The headset's own 0–5 contact level for one ear cup, with Research Kit's
/// labels and colours (Tailwind v4, converted to sRGB).
class CupContactLevel extends StatelessWidget {
  const CupContactLevel({super.key, this.side, required this.level, this.compact = false});

  /// "Left" or "Right"; shown above the dots unless [compact].
  final String? side;

  /// 0–5, or null before the headset has reported one.
  final int? level;

  /// One line ("●●●●● Headset: Excellent") for use under another display.
  final bool compact;

  /// (dot colour, text colour, label). Text uses a darker shade than the dots,
  /// as in Research Kit, so light hues like amber stay readable on white.
  static (Color, Color, String) styleFor(int? level) => switch (level) {
    null || < 0 => (const Color(0xFF99A1AF), const Color(0xFF69707D), 'Waiting…'),
    >= 5 => (const Color(0xFF2B7FFF), const Color(0xFF155DFC), 'Excellent'),
    4 => (const Color(0xFF00BBA7), const Color(0xFF009689), 'Good'),
    3 => (const Color(0xFF00BC7D), const Color(0xFF009966), 'Connected'),
    2 => (const Color(0xFFFFB900), const Color(0xFFE17100), 'Partial'),
    _ => (const Color(0xFFFF6467), const Color(0xFFFB2C36), 'No contact'),
  };

  @override
  Widget build(BuildContext context) {
    final l = level;
    final (colour, textColour, label) = styleFor(l);
    final text = l == null || l < 0 ? label : '$label ($l/5)';
    final dots = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++) ...[
          Container(
            width: compact ? 7 : 9,
            height: compact ? 7 : 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: l != null && i < l ? colour : const Color(0xFFE5E7EB),
            ),
          ),
          if (i < 4) SizedBox(width: compact ? 3 : 4),
        ],
      ],
    );
    final textStyle = TextStyle(
      fontSize: compact ? 10.5 : 11,
      fontWeight: FontWeight.w600,
      color: textColour,
    );
    return Semantics(
      label: '${side ?? 'Cup'} contact reported by the headset: $label',
      child: compact
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [dots, const SizedBox(width: 6), Text('Headset: $text', style: textStyle)],
            )
          : Column(
              children: [
                if (side != null)
                  Text(side!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111216))),
                const SizedBox(height: 6),
                dots,
                const SizedBox(height: 4),
                Text(text, style: textStyle),
              ],
            ),
    );
  }
}
