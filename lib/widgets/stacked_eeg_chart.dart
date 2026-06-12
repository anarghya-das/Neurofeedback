import 'dart:collection';
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart' show FlSpot;
import 'package:flutter/material.dart';
import '../models/stimulus_marker.dart';
import '../utils/chart_utils.dart';

class StackedEEGChart extends StatelessWidget {
  final List<Queue<FlSpot>> channelData;
  final double timeWindowSeconds;
  final double fullScaleUv;
  final List<StimulusMarker> markers;

  const StackedEEGChart({
    super.key,
    required this.channelData,
    required this.timeWindowSeconds,
    required this.fullScaleUv,
    required this.markers,
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
          markers: markers,
        ),
      ),
    );
  }
}

class _Painter extends CustomPainter {
  final List<Queue<FlSpot>> channels;
  final double timeWindow;
  final double fullScaleUv;
  final List<StimulusMarker> markers;

  _Painter({
    required this.channels,
    required this.timeWindow,
    required this.fullScaleUv,
    required this.markers,
  });

  final double _leftGutter = 72;
  final double _rightGutter = 96;
  final double _bottomAxis = 40;
  final double _topPadding = 8;
  final double _rowInnerPadding = 8;
  final double _badgeRadius = 14;
  final double _borderWidth = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = true;

    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = _borderWidth
      ..color = Colors.grey.shade700;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);

    final contentLeft = _leftGutter;
    final contentRight = size.width - _rightGutter;
    final contentTop = _topPadding;
    final contentBottom = size.height - _bottomAxis;
    final contentWidth = math.max(0, contentRight - contentLeft);
    final contentHeight = math.max(0, contentBottom - contentTop);

    final lastX = channels
        .map((q) => q.isNotEmpty ? q.last.x : 0.0)
        .reduce((a, b) => a > b ? a : b);
    final minX = lastX - timeWindow;

    final visible = <int, List<FlSpot>>{};
    for (int i = 0; i < channels.length; i++) {
      visible[i] = channels[i]
          .where((p) => p.x >= minX && p.x <= lastX)
          .toList(growable: false);
    }

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

    _drawMarkers(
      canvas,
      contentLeft,
      contentTop,
      contentBottom,
      minX,
      lastX,
      xScale,
    );

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

      if (ch > 0) {
        canvas.drawLine(
          Offset(contentLeft, rowTop),
          Offset(contentRight, rowTop),
          rowSepPaint,
        );
      }

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

      final rawPoints = visible[ch]!;

      final mean = rawPoints.isEmpty
          ? 0.0
          : rawPoints.map((p) => p.y).reduce((a, b) => a + b) /
                rawPoints.length;

      final pts = rawPoints.map((p) => FlSpot(p.x, p.y - mean)).toList();
      if (pts.length >= 2) {
        final path = Path();
        final halfHeight = (rowHeight - _rowInnerPadding * 2) / 2;

        Offset toPx(FlSpot p) {
          final x = contentLeft + (p.x - minX) * xScale;
          final clippedY = p.y.clamp(-fullScaleUv, fullScaleUv).toDouble();
          final y = rowCenter - (clippedY / fullScaleUv) * halfHeight;
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

        canvas.save();
        canvas.clipRect(
          Rect.fromLTRB(
            contentLeft,
            rowTop + _rowInnerPadding,
            contentRight,
            rowBottom - _rowInnerPadding,
          ),
        );
        canvas.drawPath(path, paint);
        canvas.restore();
      }

      final rms = _rms(visible[ch]!);
      final rmsText = rms == null
          ? '-- uVrms'
          : rms > 9999
          ? '${(rms / 1000).toStringAsFixed(1)} mVrms'
          : '${rms.toStringAsFixed(1)} uVrms';

      _drawText(
        canvas,
        rmsText,
        Offset(contentRight + 8, rowCenter - 8),
        const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
      );
    }

    final axisY = contentBottom + 4;
    const axisStyle = TextStyle(fontSize: 12, color: Colors.black87);
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

  void _drawMarkers(
    Canvas canvas,
    double contentLeft,
    double contentTop,
    double contentBottom,
    double minX,
    double lastX,
    double xScale,
  ) {
    final visibleMarkers = markers
        .where((m) => m.graphTimeSeconds >= minX && m.graphTimeSeconds <= lastX)
        .toList(growable: false);

    for (int i = 0; i < visibleMarkers.length; i++) {
      final marker = visibleMarkers[i];
      final x = contentLeft + (marker.graphTimeSeconds - minX) * xScale;
      final color = _markerColor(marker.type);

      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(
        Offset(x, contentTop),
        Offset(x, contentBottom),
        linePaint,
      );

      final tagY = contentTop + 4 + (i % 3) * 18;
      _drawMarkerTag(canvas, Offset(x + 3, tagY), marker.displayLabel, color);
    }
  }

  Color _markerColor(String type) {
    switch (type) {
      case 'AUDIO_START':
        return Colors.green.shade700;
      case 'AUDIO_STOP':
        return Colors.red.shade700;
      case 'AUDIO_PAUSE':
        return Colors.orange.shade700;
      case 'AUDIO_NEXT':
        return Colors.blue.shade700;
      default:
        return Colors.purple.shade700;
    }
  }

  void _drawMarkerTag(Canvas canvas, Offset offset, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(offset.dx, offset.dy, tp.width + 8, tp.height + 4),
      const Radius.circular(4),
    );

    final bgPaint = Paint()..color = color.withOpacity(0.92);
    canvas.drawRRect(rect, bgPaint);
    tp.paint(canvas, Offset(offset.dx + 4, offset.dy + 2));
  }

  static String _fmt(double v) => v.toStringAsFixed(v % 1 == 0 ? 0 : 1);

  double? _rms(List<FlSpot> pts) {
    if (pts.isEmpty) return null;
    double sumSq = 0;
    for (final p in pts) {
      final v = p.y;
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
        old.fullScaleUv != fullScaleUv ||
        old.markers != markers;
  }
}
