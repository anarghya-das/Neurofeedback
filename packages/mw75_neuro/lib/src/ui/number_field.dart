import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);

/// A number between − and + buttons, which can also be typed. Typed values
/// are clamped to [min]–[max] when the field loses focus or Return is pressed.
class NumberStepper extends StatefulWidget {
  const NumberStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.unit = '',
    this.decimals = 0,
    this.enabled = true,
  });

  final double value;
  final double min;
  final double max;
  final double step;
  final ValueChanged<double> onChanged;
  final String unit;
  final int decimals;
  final bool enabled;

  /// "−10", "1.25": a true minus sign, at most [decimals] places.
  static String format(double value, int decimals) {
    var text = value.abs().toStringAsFixed(decimals);
    if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
    return value < 0 && text != '0' ? '−$text' : text;
  }

  /// Reads "−10", "-10" or "1,5"; null if it is not a number.
  static double? parse(String text) =>
      double.tryParse(text.trim().replaceAll('−', '-').replaceAll(',', '.'));

  @override
  State<NumberStepper> createState() => _NumberStepperState();
}

class _NumberStepperState extends State<NumberStepper> {
  late final _text = TextEditingController(text: _show(widget.value));
  final _focus = FocusNode();

  String _show(double v) => NumberStepper.format(v, widget.decimals);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(NumberStepper old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) _text.text = _show(widget.value);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  double _clean(double v) {
    final scale = _pow10(widget.decimals);
    return ((v.clamp(widget.min, widget.max) * scale).round() / scale).toDouble();
  }

  static double _pow10(int n) => [1.0, 10.0, 100.0, 1000.0][n.clamp(0, 3)];

  void _commit() {
    final typed = NumberStepper.parse(_text.text);
    final v = typed == null ? widget.value : _clean(typed);
    _text.text = _show(v);
    if (v != widget.value) widget.onChanged(v);
  }

  void _nudge(int direction) {
    // Snap to the step grid, so 1.03 + 0.05 gives 1.05 rather than 1.08.
    final steps = (widget.value / widget.step).round() + direction;
    final v = _clean(steps * widget.step);
    _text.text = _show(v);
    if (v != widget.value) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    Widget button(IconData icon, int direction, bool active) => SizedBox(
      width: 30,
      child: IconButton(
        onPressed: enabled && active ? () => _nudge(direction) : null,
        icon: Icon(icon, size: 15),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        color: _ink,
      ),
    );
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: enabled ? Colors.white : const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          button(Icons.remove_rounded, -1, widget.value > widget.min),
          // The number ends and the unit starts at the middle, so they read
          // together.
          Expanded(
            child: TextField(
              controller: _text,
              focusNode: _focus,
              enabled: enabled,
              textAlign: widget.unit.isEmpty ? TextAlign.center : TextAlign.end,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-−]'))],
              onSubmitted: (_) => _commit(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          if (widget.unit.isNotEmpty) ...[
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                widget.unit,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ),
          ],
          button(Icons.add_rounded, 1, widget.value < widget.max),
        ],
      ),
    );
  }
}
