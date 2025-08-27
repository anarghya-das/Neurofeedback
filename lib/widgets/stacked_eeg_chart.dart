import 'dart:collection';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart' show FlSpot;
import 'package:flutter/material.dart';
import '../utils/chart_utils.dart';

/// Stacked multi-channel EEG chart with shared time axis (0..window),
/// per-row ±full-scale labels, channel badges, and right-side RMS.
class StackedEEGChart extends StatelessWidget {
  final List<Queue<FlSpot>> channelData;
  final double timeWindowSeconds;

  /// Vertical full-scale in microvolts for each row (draws ±fullScaleUv labels)
  final double fullScaleUv;

  const StackedEEGChart({
    super.key,
    required this.channelData,
    required this.timeWindowSeconds,
    required this.fullScaleUv,
  });

  @override
  Widget build(BuildContext context) {
    final nonEmpty = channelData.where((q) => q.isNotEmpty).toList();
    if (nonEmpty.isEmpty) return const Center(child: Text('No data'));

    return LayoutBuilder(
      builder: (context, constraints) => CustomPaint(
        size: Size(constraints.maxWidth, constraints.maxHeight),
        painter: _Painter(
          channels: nonEmpty,
          timeWindow: timeWindowSeconds,
          fullScaleUv: fullScaleUv,
        ),
      ),
    );
  }
}

class _Painter extends CustomPainter {
  final List<Queue<FlSpot>> channels;
  final double timeWindow;
  final double fullScaleUv;

  _Painter({
    required this.channels,
    required this.timeWindow,
    required this.fullScaleUv,
  });

  // Layout
  final double _leftGutter = 72; // badges + labels
  final double _rightGutter = 96; // RMS text
  final double _bottomAxis = 40; // time axis
  final double _topPadding = 8;
  final double _rowInnerPadding = 8;
  final double _badgeRadius = 14;
  final double _borderWidth = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = true;

    // Outer border
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = _borderWidth
      ..color = Colors.grey.shade700;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    // Content rect
    final contentLeft = _leftGutter;
    final contentRight = size.width - _rightGutter;
    final contentTop = _topPadding;
    final contentBottom = size.height - _bottomAxis;
    final contentWidth = math.max(0, contentRight - contentLeft);
    final contentHeight = math.max(0, contentBottom - contentTop);

    // Time bounds based on latest sample time across channels
    final lastX = channels
        .map((q) => q.isNotEmpty ? q.last.x : 0.0)
        .reduce((a, b) => a > b ? a : b);
    final minX = lastX - timeWindow;

    // Visible points per channel
    final visible = <int, List<FlSpot>>{};
    for (int i = 0; i < channels.length; i++) {
      visible[i] = channels[i]
          .where((p) => p.x >= minX && p.x <= lastX)
          .toList(growable: false);
    }

    // Grid lines (every 1s) from 0..timeWindow
    final xScale = contentWidth / timeWindow;
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.grey.withOpacity(0.25);
    for (int i = 0; i <= timeWindow.ceil(); i++) {
      final dx = contentLeft + i * xScale;
      canvas.drawLine(
        Offset(dx, contentTop),
        Offset(dx, contentBottom),
        gridPaint,
      );
    }

    // Row layout
    final rowCount = channels.length;
    final rowHeight = rowCount > 0 ? contentHeight / rowCount : contentHeight;
    final rowSepPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.grey.withOpacity(0.5);

    for (int ch = 0; ch < rowCount; ch++) {
      final rowTop = contentTop + ch * rowHeight;
      final rowBottom = rowTop + rowHeight;
      final rowCenter = (rowTop + rowBottom) / 2;

      // Row separator
      if (ch > 0) {
        canvas.drawLine(
          Offset(contentLeft, rowTop),
          Offset(contentRight, rowTop),
          rowSepPaint,
        );
      }

      // ±full-scale labels left
      const labelStyle = TextStyle(color: Colors.black87, fontSize: 12);
      _drawText(
        canvas,
        '+${_fmt(fullScaleUv)}uV',
        Offset(6, rowTop + 2),
        labelStyle,
      );
      _drawText(
        canvas,
        '-${_fmt(fullScaleUv)}uV',
        Offset(6, rowBottom - 18),
        labelStyle,
      );

      // Channel badge
      final badgeCenter = Offset(_leftGutter - 28, rowCenter);
      final color = ChartUtils.getChannelColor(ch);
      paint
        ..style = PaintingStyle.fill
        ..color = color;
      canvas.drawCircle(badgeCenter, _badgeRadius, paint);
      _drawCenteredText(
        canvas,
        '${ch + 1}',
        badgeCenter,
        const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      );

      // Waveform path
      final pts = visible[ch]!;
      if (pts.length >= 2) {
        final path = Path();
        final halfHeight = (rowHeight - _rowInnerPadding * 2) / 2;
        Offset toPx(FlSpot p) {
          final x = contentLeft + (p.x - minX) * xScale;
          final y = rowCenter - (p.y / fullScaleUv) * halfHeight;
          return Offset(x, y);
        }

        path.moveTo(toPx(pts.first).dx, toPx(pts.first).dy);
        for (int i = 1; i < pts.length; i++) {
          final o = toPx(pts[i]);
          path.lineTo(o.dx, o.dy);
        }
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color;
        canvas.drawPath(path, paint);
      }

      // Right-side RMS label (raw µV)
      final rms = _rms(visible[ch]!);
      final rmsText = rms != null
          ? '${rms.toStringAsFixed(1)} uVrms'
          : '-- uVrms';
      _drawText(
        canvas,
        rmsText,
        Offset(contentRight + 8, rowCenter - 8),
        const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
      );
    }

    // Bottom axis (0..timeWindow)
    final axisY = contentBottom + 4;
    final axisStyle = const TextStyle(fontSize: 12, color: Colors.black87);
    for (int i = 0; i <= timeWindow.ceil(); i++) {
      final dx = contentLeft + i * xScale;
      canvas.drawLine(
        Offset(dx, contentBottom),
        Offset(dx, contentBottom + 6),
        Paint()
          ..color = Colors.grey.shade700
          ..strokeWidth = 1,
      );
      _drawCenteredText(canvas, '$i', Offset(dx, axisY + 10), axisStyle);
    }
    _drawCenteredText(
      canvas,
      'Time (s)',
      Offset((contentLeft + contentRight) / 2, contentBottom + 22),
      const TextStyle(
        fontSize: 12,
        color: Colors.black87,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  static String _fmt(double v) => v.toStringAsFixed(v % 1 == 0 ? 0 : 1);

  double? _rms(List<FlSpot> pts) {
    if (pts.isEmpty) return null;
    double sumSq = 0;
    for (final p in pts) {
      final v = p.y; // raw µV
      sumSq += v * v;
    }
    return math.sqrt(sumSq / pts.length);
  }

  void _drawText(Canvas canvas, String text, Offset offset, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  void _drawCenteredText(
    Canvas canvas,
    String text,
    Offset center,
    TextStyle style,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = center - Offset(tp.width / 2, tp.height / 2);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _Painter old) {
    return old.channels != channels ||
        old.timeWindow != timeWindow ||
        old.fullScaleUv != fullScaleUv;
  }
}
