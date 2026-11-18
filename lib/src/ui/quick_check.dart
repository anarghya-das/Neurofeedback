import 'package:flutter/material.dart';

/// A checkbox for a test's quick check: a run of about a minute that shows a
/// build works (cues, test screen, saving) without the full test's length.
class QuickCheckToggle extends StatelessWidget {
  const QuickCheckToggle({
    super.key,
    required this.value,
    required this.seconds,
    required this.note,
    required this.onChanged,
  });

  final bool value;
  final int seconds;

  /// What the quick check cannot give, after the length.
  final String note;

  /// Null disables it (while a test runs).
  final ValueChanged<bool>? onChanged;

  static const _ink = Color(0xFF111216);
  static const _muted = Color(0xFF6B7280);

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged(!value),
      borderRadius: BorderRadius.circular(5),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: value,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Quick check, $seconds s',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: _ink),
                  ),
                  TextSpan(text: ': $note'),
                ],
              ),
              style: const TextStyle(fontSize: 11, color: _muted, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
