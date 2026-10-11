import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lsl_eeg_outlet.dart';
import '../protocol.dart';
import '../stream_processor.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _tabular = [FontFeature.tabularFigures()];

/// Recent Ch1–Ch12 samples and their LSL timestamps, for the live plot.
class EegPlotBuffer {
  EegPlotBuffer({required double seconds})
    : capacity = ((seconds + EegTracePainter.delay + 1) * Mw75Protocol.samplingRate).toInt();

  /// Sample nearest to time [t], or -1 when empty.
  int nearest(double t) {
    final i = firstAtOrAfter(t);
    if (i >= times.length) return times.length - 1;
    if (i > 0 && t - times[i - 1] < times[i] - t) return i - 1;
    return i;
  }

  final int capacity;
  final times = <double>[];
  final channels = List.generate(Mw75Protocol.eegChannelCount, (_) => <double>[]);

  void addAll(List<Mw75Sample> samples) {
    for (final s in samples) {
      times.add(s.time);
      for (var c = 0; c < channels.length; c++) {
        channels[c].add(s.values[c]);
      }
    }
    // Trim in chunks so most batches do not shift the whole list.
    final excess = times.length - capacity;
    if (excess > 250) {
      times.removeRange(0, excess);
      for (final ch in channels) {
        ch.removeRange(0, excess);
      }
    }
  }

  void clear() {
    times.clear();
    for (final ch in channels) {
      ch.clear();
    }
  }

  /// Index of the first sample at or after [t] (times are increasing).
  int firstAtOrAfter(double t) {
    var lo = 0, hi = times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// Per-channel automatic y-limits, as OpenBCI GUI's time series does it
/// (`ChannelBar.applyAutoscale` in W_TimeSeries.pde): once a second, each
/// channel's axis is set to the lowest and highest value it has in the visible
/// window, rounded out to whole µV. Limits are not symmetric and each channel
/// has its own.
class EegAutoScale {
  static const interval = 1.0;

  /// Per channel (low, high) in µV, once computed.
  final limits = <int, (double, double)>{};
  double? _updatedAt;

  /// Recomputes from samples [first]..[last) of [buffer] if a second has
  /// passed since the last update (or there is none yet).
  void refresh(EegPlotBuffer buffer, int first, int last, double now) {
    if (last - first < 2) return;
    final updated = _updatedAt;
    if (updated != null && now - updated < interval && limits.length == buffer.channels.length) return;
    _updatedAt = now;
    for (var c = 0; c < buffer.channels.length; c++) {
      final data = buffer.channels[c];
      var lo = double.infinity, hi = double.negativeInfinity;
      for (var i = first; i < last; i++) {
        lo = math.min(lo, data[i]);
        hi = math.max(hi, data[i]);
      }
      lo = lo.floorToDouble();
      hi = hi.ceilToDouble();
      // A flat channel still gets a visible range.
      if (hi - lo < 2) {
        lo -= 1;
        hi += 1;
      }
      limits[c] = (lo, hi);
    }
  }

  void clear() {
    limits.clear();
    _updatedAt = null;
  }
}

/// Scrolls by time, not by sample count: each frame shows the [window] ending
/// [delay] before now. Bluetooth delivers samples in bursts; drawing slightly
/// in the past means a burst is already in hand when its time comes, so the
/// traces glide at real speed instead of jumping whenever data lands.
///
/// Each channel gets a lane. With a fixed scale, [halfRangeUv] above or below
/// the channel's mean fills the lane and a scale bar on the right shows that
/// range. With [autoScale], each lane spans its channel's own limits (see
/// [EegAutoScale]), labelled on the right. Anything beyond is clipped to the
/// lane edge. The bottom axis is seconds before the right edge.
class EegTracePainter extends CustomPainter {
  EegTracePainter(
    this.buffer, {
    required Listenable repaint,
    required this.window,
    this.halfRangeUv = 100,
    this.autoScale,
    this.hover,
    double Function()? clock,
  }) : clock = clock ?? LslEegOutlet.localClock,
       super(repaint: repaint);

  /// LSL time now; injectable for tests.
  final double Function() clock;

  static const delay = 0.35;
  static const maxWindow = 30.0;
  static const windowOptions = [2.0, 4.0, 5.0, 10.0, 20.0, 30.0];
  static const scaleOptions = [10, 20, 50, 100, 200, 500, 1000];

  final EegPlotBuffer buffer;
  final double window;
  final double halfRangeUv;

  /// Per-channel automatic limits; when set, [halfRangeUv] is ignored.
  final EegAutoScale? autoScale;
  final Offset? hover;

  static const _left = 36.0, _right = 54.0, _bottom = 18.0;

  static String _uv(double v) => '${v > 0 ? '+' : (v < 0 ? '−' : '')}${v.abs().round()} µV';

  @override
  void paint(Canvas canvas, Size size) {
    final end = clock() - delay;
    final start = end - window;
    final first = buffer.firstAtOrAfter(start);
    final last = buffer.firstAtOrAfter(end); // exclusive
    final count = last - first;
    final auto = autoScale;
    auto?.refresh(buffer, first, last, end);

    // Room on the right for the scale bar, or for the widest per-channel limit.
    var right = _right;
    if (auto != null && auto.limits.isNotEmpty) {
      final measure = TextPainter(textDirection: TextDirection.ltr);
      for (final (lo, hi) in auto.limits.values) {
        for (final v in [lo, hi]) {
          measure.text = TextSpan(
            text: _uv(v),
            style: const TextStyle(fontSize: 10, fontFeatures: _tabular),
          );
          measure.layout();
          right = math.max(right, measure.width + 12);
        }
      }
    }
    final plot = Rect.fromLTRB(_left, 0, size.width - right, size.height - _bottom);
    if (plot.width <= 0 || plot.height <= 0) return;
    final lanes = buffer.channels.length;
    final laneHeight = plot.height / lanes;
    // The range fills 45% of the lane each way, leaving a gap between lanes.
    final unit = laneHeight * 0.45 / halfRangeUv;
    final label = TextPainter(textDirection: TextDirection.ltr);
    void text(String t, Offset at, {bool right = false, bool center = false, Color color = _muted, Color? background}) {
      label.text = TextSpan(
        text: t,
        style: TextStyle(fontSize: 10, color: color, fontFeatures: _tabular),
      );
      label.layout();
      final o = at + Offset(right ? -label.width : (center ? -label.width / 2 : 0), -label.height / 2);
      if (background != null) {
        canvas.drawRect(Rect.fromLTWH(o.dx - 2, o.dy, label.width + 4, label.height), Paint()..color = background);
      }
      label.paint(canvas, o);
    }

    double x(double t) => plot.left + plot.width * (t - start) / window;

    // Time grid and axis: seconds before the right edge.
    final grid = Paint()..color = const Color(0xFFEEF0F3);
    final step = window <= 5 ? 1.0 : (window <= 10 ? 2.0 : 5.0);
    for (var back = 0.0; back <= window + 1e-9; back += step) {
      final px = plot.right - plot.width * back / window;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), grid);
      text(back == 0 ? '0 s' : '−${back.round()} s', Offset(px, plot.bottom + 9), center: back > 0, right: back == 0);
    }

    final columns = plot.width.floor();
    final trace = Paint()
      ..color = const Color(0xFF2B4C7E)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final means = List.filled(lanes, 0.0);

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(plot.left, plot.top, plot.right, plot.bottom));
    for (var c = 0; c < lanes; c++) {
      final mid = plot.top + laneHeight * (c + 0.5);
      canvas.drawLine(Offset(plot.left, mid), Offset(plot.right, mid), grid);
      if (count < 2) continue;
      final data = buffer.channels[c];
      final limit = auto?.limits[c];
      final double Function(double) y;
      if (limit != null) {
        // The channel's own limits span 90% of the lane.
        final (lo, hi) = limit;
        final scale = laneHeight * 0.9 / (hi - lo);
        y = (v) => (mid - (v - (lo + hi) / 2) * scale).clamp(mid - laneHeight / 2, mid + laneHeight / 2);
      } else {
        var mean = 0.0;
        for (var i = first; i < last; i++) {
          mean += data[i];
        }
        mean /= count;
        means[c] = mean;
        y = (v) => (mid - (v - mean) * unit).clamp(mid - laneHeight / 2, mid + laneHeight / 2);
      }
      final path = Path();
      if (count <= columns * 2) {
        // Few samples per pixel: join them all.
        path.moveTo(x(buffer.times[first]), y(data[first]));
        for (var i = first + 1; i < last; i++) {
          path.lineTo(x(buffer.times[i]), y(data[i]));
        }
      } else {
        // Many samples per pixel (long windows): each pixel column draws its
        // lowest and highest value, so short spikes stay visible.
        var column = -1;
        var lo = 0.0, hi = 0.0;
        var started = false;
        void flush() {
          if (column < 0) return;
          final px = plot.left + column + 0.5;
          if (started) {
            path.lineTo(px, y(hi));
          } else {
            path.moveTo(px, y(hi));
            started = true;
          }
          path.lineTo(px, y(lo));
        }

        for (var i = first; i < last; i++) {
          final col = (x(buffer.times[i]) - plot.left).floor();
          if (col != column) {
            flush();
            column = col;
            lo = hi = data[i];
          } else {
            lo = math.min(lo, data[i]);
            hi = math.max(hi, data[i]);
          }
        }
        flush();
      }
      canvas.drawPath(path, trace);
    }
    canvas.restore();

    for (var c = 0; c < lanes; c++) {
      text('Ch${c + 1}', Offset(0, plot.top + laneHeight * (c + 0.5)));
    }

    if (auto != null) {
      // Each channel's limits beside its lane, as OpenBCI labels its axes.
      for (var c = 0; c < lanes; c++) {
        final limit = auto.limits[c];
        if (limit == null) continue;
        final mid = plot.top + laneHeight * (c + 0.5);
        if (laneHeight >= 26) {
          text(_uv(limit.$2), Offset(plot.right + 6, mid - laneHeight * 0.45 + 5));
          text(_uv(limit.$1), Offset(plot.right + 6, mid + laneHeight * 0.45 - 5));
        } else {
          // Too short for two labels: the span instead.
          text('${(limit.$2 - limit.$1).round()} µV', Offset(plot.right + 6, mid));
        }
      }
    } else {
      _drawScaleBar(canvas, plot, laneHeight, unit, text);
    }

    final h = hover;
    if (h != null && plot.contains(h) && count > 0) {
      // Values at the hovered time: as measured with automatic limits (which
      // are in measured µV), else relative to each lane's mean like the traces.
      final t = start + (h.dx - plot.left) / plot.width * window;
      final i = buffer.nearest(t);
      canvas.drawLine(Offset(h.dx, plot.top), Offset(h.dx, plot.bottom), Paint()..color = const Color(0xFF898781));
      final readRight = h.dx + 90 < plot.right;
      for (var c = 0; c < lanes; c++) {
        if (i < first || i >= last) break;
        final v = buffer.channels[c][i] - (auto != null ? 0 : means[c]);
        text(
          '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(v.abs() >= 100 ? 0 : 1)} µV',
          Offset(h.dx + (readRight ? 6 : -6), plot.top + laneHeight * (c + 0.5)),
          right: !readRight,
          color: _ink,
          background: Colors.white,
        );
      }
      text(
        '−${(end - t).toStringAsFixed(2)} s',
        Offset(h.dx, plot.bottom + 9),
        center: true,
        color: _ink,
        background: Colors.white,
      );
    }
  }

  /// The full ±range of one lane, beside the last lane.
  void _drawScaleBar(
    Canvas canvas,
    Rect plot,
    double laneHeight,
    double unit,
    void Function(String, Offset, {bool right, bool center, Color color, Color? background}) text,
  ) {
    final lanes = buffer.channels.length;
    final barX = plot.right + 12;
    final barMid = plot.top + laneHeight * (lanes - 0.5);
    final bar = Paint()
      ..color = _ink
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(barX, barMid - halfRangeUv * unit), Offset(barX, barMid + halfRangeUv * unit), bar);
    for (final dy in [-halfRangeUv * unit, halfRangeUv * unit]) {
      canvas.drawLine(Offset(barX - 3, barMid + dy), Offset(barX + 3, barMid + dy), bar);
    }
    text('${(2 * halfRangeUv).round()}', Offset(barX + 6, barMid - 6), color: _ink);
    text('µV', Offset(barX + 6, barMid + 6), color: _ink);
  }

  @override
  bool shouldRepaint(covariant EegTracePainter old) =>
      old.buffer != buffer ||
      old.window != window ||
      old.halfRangeUv != halfRangeUv ||
      old.autoScale != autoScale ||
      old.hover != hover;
}
