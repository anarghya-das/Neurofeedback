import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../band_power.dart';
import '../eeg_filters.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _tabular = [FontFeature.tabularFigures()];

/// Colour for a channel's spectrum line: its position on the cup (1–6) picks
/// one of six validated categorical hues, and the cup picks the line style
/// (left solid, right dashed). Twelve separate hues cannot all stay
/// distinguishable, colour-blind readers included; six can.
const _positionColors = [
  Color(0xFF2A78D6), // blue
  Color(0xFFEB6834), // orange
  Color(0xFF1BAF7A), // aqua
  Color(0xFFEDA100), // yellow
  Color(0xFFE87BA4), // magenta
  Color(0xFF008300), // green
];

Color _channelColor(int c) => _positionColors[c % 6];
bool _channelDashed(int c) => c >= 6;

/// Live Welch spectra, one line per channel, from 0 Hz, with the EEG bands
/// marked and power on a log or linear scale. Hovering shows every channel's
/// value at that frequency.
///
/// [spectrum] pairs each channel index (0-based) with its spectrum; null or
/// empty shows a placeholder. The lowest point is the first bin above 0 Hz
/// (~1 Hz): 0 Hz itself is the electrodes' offset, which is removed.
class ChannelSpectrumPlot extends StatefulWidget {
  const ChannelSpectrumPlot({super.key, required this.spectrum, required this.filters, this.mainsHz});

  final List<(int, PowerSpectrum)>? spectrum;
  final EegFilterSettings filters;

  /// Where the notch found mains interference, to mark it; defaults to the
  /// nominal 50/60 Hz.
  final double? mainsHz;

  @override
  State<ChannelSpectrumPlot> createState() => _ChannelSpectrumPlotState();
}

class _ChannelSpectrumPlotState extends State<ChannelSpectrumPlot> {
  Offset? _hover;

  /// Log power shows small and large peaks together; linear starts at 0.
  bool _logPower = true;

  /// Highest frequency shown, Hz; 0 means up to Nyquist.
  int _upTo = 0;

  @override
  Widget build(BuildContext context) {
    final s = widget.spectrum;
    if (s == null || s.isEmpty) {
      return const Center(
        child: Text(
          'The spectrum appears about 2 s after streaming starts.',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
      );
    }
    final channels = [for (final (c, _) in s) c];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: channels.length > 1 ? _SpectrumLegend(channels: channels) : const SizedBox.shrink()),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Choice<int>(
                  label: 'Up to',
                  value: _upTo,
                  options: const {30: '30 Hz', 50: '50 Hz', 100: '100 Hz', 0: 'Nyquist'},
                  onChanged: (v) => setState(() {
                    _upTo = v;
                    _hover = null;
                  }),
                ),
                const SizedBox(height: 2),
                _Choice<bool>(
                  label: 'Power',
                  value: _logPower,
                  options: const {true: 'Log', false: 'Linear'},
                  onChanged: (v) => setState(() => _logPower = v),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: MouseRegion(
            onHover: (e) => setState(() => _hover = e.localPosition),
            onExit: (_) => setState(() => _hover = null),
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SpectrumPainter(
                  s,
                  widget.filters,
                  hover: _hover,
                  logPower: _logPower,
                  upTo: _upTo.toDouble(),
                  mainsHz: widget.mainsHz ?? widget.filters.mainsHz,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A label and a row of mutually exclusive text options, for plot settings.
class _Choice<T> extends StatelessWidget {
  const _Choice({required this.label, required this.value, required this.options, required this.onChanged});

  final String label;
  final T value;

  /// Option values with their labels, in order.
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget option(T v, String text) {
      final selected = v == value;
      return InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: selected ? null : () => onChanged(v),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEDEEF1) : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? _ink : _muted,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 10.5, color: _muted)),
        const SizedBox(width: 4),
        for (final e in options.entries) option(e.key, e.value),
      ],
    );
  }
}

/// Channels grouped by cup, each with its line sample; text stays in ink.
class _SpectrumLegend extends StatelessWidget {
  const _SpectrumLegend({required this.channels});

  final List<int> channels;

  @override
  Widget build(BuildContext context) {
    Widget group(String cup, Iterable<int> members) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          cup,
          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _muted),
        ),
        const SizedBox(width: 6),
        for (final c in members)
          Padding(
            padding: const EdgeInsets.only(right: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CustomPaint(size: const Size(16, 8), painter: _LineSamplePainter(c)),
                const SizedBox(width: 3),
                Text('Ch${c + 1}', style: const TextStyle(fontSize: 10.5, color: _ink)),
              ],
            ),
          ),
      ],
    );
    final left = channels.where((c) => c < 6);
    final right = channels.where((c) => c >= 6);
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        if (left.isNotEmpty) group('Left (solid)', left),
        if (right.isNotEmpty) group('Right (dashed)', right),
      ],
    );
  }
}

class _LineSamplePainter extends CustomPainter {
  _LineSamplePainter(this.channel);

  final int channel;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, size.height / 2);
    canvas.drawPath(_channelDashed(channel) ? _dash(path) : path, _linePaint(channel));
  }

  @override
  bool shouldRepaint(covariant _LineSamplePainter old) => old.channel != channel;
}

Paint _linePaint(int channel) => Paint()
  ..color = _channelColor(channel)
  ..style = PaintingStyle.stroke
  ..strokeWidth = 1.5
  ..strokeJoin = StrokeJoin.round;

/// [path] as 5 px dashes with 3 px gaps.
Path _dash(Path path) {
  final out = Path();
  for (final metric in path.computeMetrics()) {
    for (var d = 0.0; d < metric.length; d += 8) {
      out.addPath(metric.extractPath(d, math.min(d + 5, metric.length)), Offset.zero);
    }
  }
  return out;
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter(
    this.spectra,
    this.filters, {
    this.hover,
    required this.logPower,
    required this.mainsHz,
    required this.upTo,
  });

  /// Highest frequency to show, Hz; 0 (or anything past Nyquist) shows all.
  final double upTo;

  final List<(int, PowerSpectrum)> spectra;
  final EegFilterSettings filters;
  final Offset? hover;
  final bool logPower;
  final double mainsHz;

  /// Greek letters for band names that do not fit at full length.
  static const _bandSymbols = {
    EegBand.delta: 'δ',
    EegBand.theta: 'θ',
    EegBand.alpha: 'α',
    EegBand.beta: 'β',
    EegBand.gamma: 'γ',
  };
  static const _left = 46.0, _bottom = 18.0, _top = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_left, _top, size.width - 4, size.height - _bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final binHz = spectra.first.$2.binHz;
    // Bin 0 (0 Hz) is the electrode offset, removed by the detrend.
    const firstBin = 1;
    // Up to Nyquist, half the sample rate: the highest frequency the samples
    // can represent.
    final nyquistBin = spectra.first.$2.density.length - 1;
    final lastBin = upTo > 0 ? math.min(nyquistBin, (upTo / binHz).ceil()) : nyquistBin;
    final maxHz = upTo > 0 ? math.min(upTo, nyquistBin * binHz) : nyquistBin * binHz;
    double log10(double v) => math.log(v) / math.ln10;
    // Plotted value: log10 of the density, or the density itself.
    double value(double density) => logPower ? log10(density) : density;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final (_, s) in spectra) {
      for (var k = firstBin; k <= lastBin; k++) {
        if (s.density[k] <= 0) continue;
        final v = value(s.density[k]);
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (!lo.isFinite) return;
    final List<double> ticks;
    if (logPower) {
      // Whole decades, so the scale only moves when the signal changes a lot.
      lo = lo.floorToDouble();
      hi = math.max(hi.ceilToDouble(), lo + 1);
      ticks = [for (var d = lo; d <= hi + 1e-9; d++) d];
    } else {
      lo = 0;
      hi = _niceCeiling(hi);
      ticks = [for (var i = 0; i <= 4; i++) hi * i / 4];
    }
    double x(double f) => plot.left + plot.width * f / maxHz;
    double y(double v) => plot.bottom - plot.height * (v - lo) / (hi - lo);
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(
      String t,
      Offset at, {
      bool right = false,
      bool center = false,
      Color color = _muted,
      FontWeight? weight,
    }) {
      label.text = TextSpan(
        text: t,
        style: TextStyle(fontSize: 10, color: color, fontWeight: weight, fontFeatures: _tabular),
      );
      label.layout();
      label.paint(canvas, at + Offset(right ? -label.width : (center ? -label.width / 2 : 0), -label.height / 2));
    }

    // Bands: alternate neutral washes, named in muted ink, so they never
    // compete with the channel colours.
    for (final (i, band) in EegBand.values.indexed) {
      final from = x(band.low), to = x(math.min(band.high, maxHz));
      if (i.isEven) {
        canvas.drawRect(Rect.fromLTRB(from, plot.top, to, plot.bottom), Paint()..color = const Color(0xFFF6F6F4));
      }
      // The full name where it fits, else its Greek letter, else nothing.
      for (final name in [band.label, _bandSymbols[band]!]) {
        label.text = TextSpan(text: name, style: const TextStyle(fontSize: 10));
        label.layout();
        if (label.width + 4 <= to - from) {
          text(name, Offset((from + to) / 2, plot.top - 8), center: true);
          break;
        }
      }
    }
    final grid = Paint()..color = const Color(0xFFE1E0D9);
    for (final t in ticks) {
      canvas.drawLine(Offset(plot.left, y(t)), Offset(plot.right, y(t)), grid);
      text(_power(logPower ? math.pow(10, t).toDouble() : t), Offset(plot.left - 6, y(t)), right: true);
    }
    text('µV²/Hz', Offset(plot.left - 6, plot.top - 8), right: true);
    // The finest tick step that leaves room for its labels.
    final step = [1.0, 2.0, 5.0, 10.0, 25.0, 50.0].firstWhere((s) => plot.width / (maxHz / s) >= 44, orElse: () => 50);
    for (var f = 0.0; f < maxHz - step / 2; f += step) {
      if (f > 0) canvas.drawLine(Offset(x(f), plot.top), Offset(x(f), plot.bottom), grid);
      text('${f.round()}', Offset(x(f), plot.bottom + 9), center: true);
    }
    // The top of the range closes the axis, with the unit.
    text('${maxHz.toStringAsFixed(0)} Hz', Offset(plot.right, plot.bottom + 9), right: true);
    if (filters.notch && mainsHz < maxHz) {
      canvas.drawLine(
        Offset(x(mainsHz), plot.top),
        Offset(x(mainsHz), plot.bottom),
        Paint()..color = const Color(0xFFC3C2B7),
      );
      text('notch', Offset(x(mainsHz) + 3, plot.top + 6), color: _muted);
    }

    canvas.save();
    canvas.clipRect(plot);
    for (final (c, s) in spectra) {
      final path = Path();
      var started = false;
      for (var k = firstBin; k <= lastBin; k++) {
        if (s.density[k] <= 0) continue;
        final o = Offset(x(k * binHz), y(value(s.density[k])));
        if (started) {
          path.lineTo(o.dx, o.dy);
        } else {
          path.moveTo(o.dx, o.dy);
          started = true;
        }
      }
      canvas.drawPath(_channelDashed(c) ? _dash(path) : path, _linePaint(c));
    }
    canvas.restore();

    final h = hover;
    if (h != null && plot.contains(h)) _drawReadout(canvas, plot, h, binHz, x, y, value);
  }

  /// Crosshair at the hovered frequency and every channel's value there.
  void _drawReadout(
    Canvas canvas,
    Rect plot,
    Offset h,
    double binHz,
    double Function(double) x,
    double Function(double) y,
    double Function(double) value,
  ) {
    final nyquistBin = spectra.first.$2.density.length - 1;
    final maxHz = upTo > 0 ? math.min(upTo, nyquistBin * binHz) : nyquistBin * binHz;
    final hovered = (h.dx - plot.left) / plot.width * maxHz;
    final k = (hovered / binHz).round().clamp(1, nyquistBin);
    final f = k * binHz;
    canvas.drawLine(Offset(x(f), plot.top), Offset(x(f), plot.bottom), Paint()..color = const Color(0xFF898781));
    for (final (c, s) in spectra) {
      if (s.density[k] <= 0) continue;
      final o = Offset(x(f), y(value(s.density[k])));
      canvas.drawCircle(o, 4, Paint()..color = Colors.white);
      canvas.drawCircle(o, 3, Paint()..color = _channelColor(c));
    }

    // Two columns, left cup then right cup, like the ear-cup map.
    final rows = <List<(int, double)>>[[], []];
    for (final (c, s) in spectra) {
      rows[c < 6 ? 0 : 1].add((c, s.density[k]));
    }
    final columns = rows.where((r) => r.isNotEmpty).toList();
    const rowHeight = 14.0, colWidth = 92.0, pad = 8.0;
    final lines = columns.map((r) => r.length).reduce(math.max);
    final box = Size(pad * 2 + colWidth * columns.length, pad * 2 + 16 + rowHeight * lines);
    var left = x(f) + 12;
    if (left + box.width > plot.right) left = x(f) - 12 - box.width;
    final top = (h.dy - box.height / 2).clamp(plot.top, math.max(plot.top, plot.bottom - box.height)).toDouble();
    final rect = Rect.fromLTWH(left, top, box.width, box.height);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(6)), Paint()..color = Colors.white);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()
        ..color = const Color(0x1A0B0B0B)
        ..style = PaintingStyle.stroke,
    );
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void write(String t, Offset at, {Color color = _ink, FontWeight? weight}) {
      tp.text = TextSpan(
        text: t,
        style: TextStyle(fontSize: 10.5, color: color, fontWeight: weight, fontFeatures: _tabular),
      );
      tp.layout();
      tp.paint(canvas, at);
    }

    write('${f.toStringAsFixed(1)} Hz · µV²/Hz', rect.topLeft + const Offset(pad, pad), weight: FontWeight.w700);
    for (final (ci, column) in columns.indexed) {
      for (final (ri, (c, v)) in column.indexed) {
        final at = rect.topLeft + Offset(pad + ci * colWidth, pad + 16 + ri * rowHeight);
        final mid = at + const Offset(0, 7);
        final sample = Path()
          ..moveTo(mid.dx, mid.dy)
          ..lineTo(mid.dx + 12, mid.dy);
        canvas.drawPath(_channelDashed(c) ? _dash(sample) : sample, _linePaint(c)..strokeWidth = 2);
        write('Ch${c + 1}', at + const Offset(16, 0));
        write(_power(v), at + const Offset(48, 0), color: const Color(0xFF52514E));
      }
    }
  }

  /// 1, 2 or 5 × a power of ten, at least [v].
  static double _niceCeiling(double v) {
    if (v <= 0) return 1;
    final decade = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 5.0, 10.0]) {
      if (m * decade >= v) return m * decade;
    }
    return 10 * decade;
  }

  static String _power(double v) {
    if (v == 0) return '0';
    if (v >= 100) return v.round().toString();
    if (v >= 1) return v.toStringAsFixed(v >= 10 ? 1 : 2);
    return v.toStringAsPrecision(2);
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter old) =>
      old.spectra != spectra ||
      old.filters != filters ||
      old.hover != hover ||
      old.logPower != logPower ||
      old.upTo != upTo ||
      old.mainsHz != mainsHz;
}
