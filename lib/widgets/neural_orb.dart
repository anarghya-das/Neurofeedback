import 'dart:math' as math;

import 'package:flutter/material.dart';

class NeuralOrb extends StatefulWidget {
  const NeuralOrb({
    super.key,
    required this.ratios,
    required this.calibrating,
    required this.ready,
  });

  final List<double>? ratios;
  final bool calibrating;
  final bool ready;

  static const bandNames = ['Delta', 'Theta', 'Alpha', 'Beta', 'Gamma'];
  static const bandColors = [
    Color(0xFF0EA5E9),
    Color(0xFF7C3AED),
    Color(0xFF14B8A6),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
  ];

  @override
  State<NeuralOrb> createState() => _NeuralOrbState();
}

class _NeuralOrbState extends State<NeuralOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _dominantBand {
    if (!widget.ready || widget.ratios == null) return null;
    var bestIndex = 0;
    var bestChange = 0.0;
    for (var i = 0; i < math.min(5, widget.ratios!.length); i++) {
      final change = (widget.ratios![i] - 1).abs();
      if (change > bestChange) {
        bestChange = change;
        bestIndex = i;
      }
    }
    return bestChange < 0.08 ? null : bestIndex;
  }

  @override
  Widget build(BuildContext context) {
    final dominant = _dominantBand;
    final status = widget.calibrating
        ? 'Calibrating baseline'
        : !widget.ready
        ? 'Waiting for experiment'
        : dominant == null
        ? 'Activity is close to baseline'
        : '${NeuralOrb.bandNames[dominant]} shows the largest change';

    return Column(
      children: [
        Expanded(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _NeuralFieldPainter(
                progress: _controller.value,
                ratios: widget.ratios,
                calibrating: widget.calibrating,
                ready: widget.ready,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Text(
          status,
          style: const TextStyle(
            color: Color(0xFF475569),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        const Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            _LegendItem(color: Color(0xFF0EA5E9), label: 'Delta'),
            _LegendItem(color: Color(0xFF7C3AED), label: 'Theta'),
            _LegendItem(color: Color(0xFF14B8A6), label: 'Alpha'),
            _LegendItem(color: Color(0xFFF59E0B), label: 'Beta'),
            _LegendItem(color: Color(0xFFEC4899), label: 'Gamma'),
            _LegendItem(
              color: Color(0xFFCBD5E1),
              label: 'Dim = near baseline / unavailable',
            ),
          ],
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 9)),
      ],
    );
  }
}

class _NeuralFieldPainter extends CustomPainter {
  const _NeuralFieldPainter({
    required this.progress,
    required this.ratios,
    required this.calibrating,
    required this.ready,
  });

  final double progress;
  final List<double>? ratios;
  final bool calibrating;
  final bool ready;

  List<double> get _changes => List.generate(5, (index) {
    if (!ready || ratios == null || index >= ratios!.length) return 0.0;
    final value = ratios![index];
    return value.isFinite ? (value - 1).abs().clamp(0.0, 1.25) : 0.0;
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.47);
    final changes = _changes;
    var dominant = 0;
    for (var i = 1; i < changes.length; i++) {
      if (changes[i] > changes[dominant]) dominant = i;
    }

    final overall = changes.reduce((a, b) => a + b) / changes.length;
    final meaningful = ready && changes[dominant] >= 0.08;
    final fieldColor = meaningful
        ? NeuralOrb.bandColors[dominant]
        : const Color(0xFF94A3B8);
    final brightness = meaningful
        ? (0.38 + overall * 0.7).clamp(0.38, 1.0)
        : 0.24;
    final pulse =
        1 + math.sin(progress * math.pi * 2) * (0.015 + overall * 0.025);
    final lobeWidth = math.min(size.width * 0.19, size.height * 0.28) * pulse;
    final lobeHeight = lobeWidth * 1.2;
    final gap = lobeWidth * 0.12;
    final left = center.translate(-lobeWidth - gap / 2, 0);
    final right = center.translate(gap / 2, 0);

    final glowRect = Rect.fromCenter(
      center: center,
      width: lobeWidth * 4.8,
      height: lobeHeight * 2.5,
    );
    canvas.drawOval(
      glowRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            fieldColor.withValues(alpha: brightness * 0.2),
            fieldColor.withValues(alpha: brightness * 0.05),
            Colors.transparent,
          ],
        ).createShader(glowRect),
    );

    _drawLobe(
      canvas,
      left,
      lobeWidth,
      lobeHeight,
      fieldColor,
      brightness,
      false,
    );
    _drawLobe(
      canvas,
      right,
      lobeWidth,
      lobeHeight,
      fieldColor,
      brightness,
      true,
    );

    final bridgePaint = Paint()
      ..color = fieldColor.withValues(alpha: brightness * 0.45)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    for (var i = -2; i <= 2; i++) {
      final y = center.dy + i * lobeHeight * 0.17;
      final wave = math.sin(progress * math.pi * 2 + i) * 4;
      final path = Path()
        ..moveTo(center.dx - gap / 2 - 5, y)
        ..quadraticBezierTo(center.dx, y + wave, center.dx + gap / 2 + 5, y);
      canvas.drawPath(path, bridgePaint);
    }

    if (calibrating) {
      canvas.drawArc(
        Rect.fromCenter(
          center: center,
          width: lobeWidth * 4.25,
          height: lobeHeight * 2.05,
        ),
        -math.pi / 2,
        progress * math.pi * 2,
        false,
        Paint()
          ..color = const Color(0xFFF59E0B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _drawLobe(
    Canvas canvas,
    Offset origin,
    double width,
    double height,
    Color color,
    double brightness,
    bool mirror,
  ) {
    final rect = Rect.fromLTWH(
      origin.dx,
      origin.dy - height / 2,
      width,
      height,
    );
    final path = Path()
      ..moveTo(mirror ? rect.left : rect.right, rect.top + height * 0.12)
      ..cubicTo(
        rect.left + width * 0.15,
        rect.top - height * 0.03,
        rect.left - width * 0.08,
        rect.top + height * 0.32,
        rect.left + width * 0.06,
        rect.top + height * 0.5,
      )
      ..cubicTo(
        rect.left - width * 0.06,
        rect.top + height * 0.72,
        rect.left + width * 0.18,
        rect.bottom + height * 0.03,
        mirror ? rect.left : rect.right,
        rect.bottom - height * 0.1,
      )
      ..cubicTo(
        rect.right + width * 0.08,
        rect.bottom - height * 0.3,
        rect.right + width * 0.04,
        rect.top + height * 0.25,
        mirror ? rect.left : rect.right,
        rect.top + height * 0.12,
      )
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          center: mirror ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            color.withValues(alpha: brightness * 0.95),
            color.withValues(alpha: brightness * 0.38),
            const Color(0xFF1E293B).withValues(alpha: 0.6),
          ],
        ).createShader(rect),
    );

    final filamentPaint = Paint()
      ..color = Colors.white.withValues(alpha: brightness * 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (var i = 1; i <= 5; i++) {
      final y = rect.top + i * height / 6;
      final direction = mirror ? -1.0 : 1.0;
      final filament = Path()
        ..moveTo(rect.center.dx, y)
        ..quadraticBezierTo(
          rect.center.dx + direction * width * 0.28,
          y + math.sin(progress * math.pi * 2 + i) * 5,
          rect.center.dx + direction * width * 0.43,
          y - height * 0.05,
        );
      canvas.drawPath(filament, filamentPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NeuralFieldPainter oldDelegate) => true;
}
