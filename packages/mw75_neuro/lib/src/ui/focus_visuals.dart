import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Which animation shows the focus score.
enum FocusVisual {
  flame('Flame'),
  rocket('Rocket');

  const FocusVisual(this.label);

  final String label;
}

/// An animated picture of the focus score, for neurofeedback.
///
/// The design follows the neurofeedback literature. Gamified displays have not
/// trained better than a plain bar, but they keep people engaged over long
/// sessions, so this sits beside the number and bar rather than replacing them.
/// The picture is proportional to the score and changes smoothly (no flashes or
/// jumps, which distract and tire): the flame grows taller, hotter and brighter,
/// the rocket rises and the stars stream past faster. A separate reward shows
/// only at or above the personal [target]: sparks fly from the flame, the rocket
/// crosses the dashed target line and its altitude climbs. With reduced motion
/// turned on in the system, it shows a still picture.
class FocusVisualView extends StatefulWidget {
  const FocusVisualView({
    super.key,
    required this.visual,
    required this.level,
    required this.target,
    this.paused = false,
    this.climbSeconds = 0,
  });

  final FocusVisual visual;

  /// Focus 0–1, or null before the first score.
  final double? level;

  /// The feedback target 0–1.
  final double target;

  /// The signal is too noisy to score: the picture dims and holds.
  final bool paused;

  /// Seconds at or above the target so far, shown as the rocket's altitude.
  final double climbSeconds;

  /// Altitude per second above the target.
  static const metresPerSecond = 10.0;

  @override
  State<FocusVisualView> createState() => _FocusVisualViewState();
}

class _FocusVisualViewState extends State<FocusVisualView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _frame = ValueNotifier(0);
  var _flame = _FlameSim(math.Random());
  var _rocket = _RocketSim(math.Random());
  Duration? _last;

  /// What is drawn eases toward the inputs, which change about twice a second,
  /// so the picture moves continuously.
  late double _shown = widget.level ?? 0;
  late double _target = widget.target;
  late double _dim = _dimTarget;
  late double _altitude = widget.climbSeconds * FocusVisualView.metresPerSecond;

  bool get _active => !widget.paused && widget.level != null;
  double get _dimTarget => _active ? 0 : 1;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    if (last == null) return;
    final dt = ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    double ease(double from, double to, double tau) => from + (to - from) * (1 - math.exp(-dt / tau));
    _shown = ease(_shown, widget.level ?? 0, 0.6);
    _target = ease(_target, widget.target, 0.6);
    _dim = ease(_dim, _dimTarget, 0.4);
    _altitude = ease(_altitude, widget.climbSeconds * FocusVisualView.metresPerSecond, 0.8);
    _step(dt);
    _frame.value++;
  }

  void _step(double dt) {
    final reward = _active && (widget.level ?? 0) >= widget.target;
    switch (widget.visual) {
      case FocusVisual.flame:
        _flame.step(dt, _shown, reward: reward, active: _active);
      case FocusVisual.rocket:
        _rocket.step(dt, _shown, active: _active);
    }
  }

  /// A still picture: a fresh, seeded simulation run for a few seconds at the
  /// current values, so the same score always gives the same picture.
  void _still() {
    _shown = widget.level ?? 0;
    _target = widget.target;
    _dim = _dimTarget;
    _altitude = widget.climbSeconds * FocusVisualView.metresPerSecond;
    _flame = _FlameSim(math.Random(1));
    _rocket = _RocketSim(math.Random(1));
    for (var i = 0; i < 60; i++) {
      _step(0.05);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      if (_ticker.isActive) _ticker.stop();
      _still();
    } else if (!_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
    final painter = switch (widget.visual) {
      FocusVisual.flame => _FlamePainter(this, repaint: _frame),
      FocusVisual.rocket => _RocketPainter(this, repaint: _frame),
    };
    const caption = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: Color(0xCCFFFFFF),
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(child: CustomPaint(painter: painter)),
          ),
          if (widget.visual == FocusVisual.rocket && widget.level != null)
            Positioned(
              left: 12,
              top: 10,
              child: ValueListenableBuilder(
                valueListenable: _frame,
                builder: (context, _, _) => Text('Altitude ${_altitude.round()} m', style: caption),
              ),
            ),
          if (!_active)
            Positioned(
              right: 12,
              top: 10,
              child: Text(
                widget.level != null
                    ? 'Paused: too noisy'
                    : (widget.paused ? 'No clean EEG yet' : 'Waiting for a score'),
                style: caption,
              ),
            ),
        ],
      ),
    );
  }
}

/// One glowing particle, in a unit box: x 0–1 left to right, y 0–1 up from
/// the bottom.
class _Particle {
  _Particle(this.x, this.y, this.vx, this.vy, this.life, this.size, this.seed, {this.hue = 0});

  double x, y, vx, vy;
  double age = 0;
  final double life;
  final double size;
  final double seed;

  /// Where on the fire colour ramp the particle starts: 0 white-hot, higher
  /// is cooler.
  final double hue;

  double get progress => (age / life).clamp(0.0, 1.0);
}

/// Fire colour along 0–1: white-yellow core, orange, red, gone.
Color _fireColor(double t, double alpha) {
  const stops = [
    (0.0, Color(0xFFFFF6D0)),
    (0.22, Color(0xFFFFC94D)),
    (0.5, Color(0xFFFF7A1A)),
    (0.8, Color(0xFFD7351E)),
    (1.0, Color(0x00B0201A)),
  ];
  t = t.clamp(0.0, 1.0);
  for (var i = 0; i < stops.length - 1; i++) {
    final (a, ca) = stops[i];
    final (b, cb) = stops[i + 1];
    if (t <= b) {
      final c = Color.lerp(ca, cb, (t - a) / (b - a))!;
      return c.withValues(alpha: c.a * alpha);
    }
  }
  return const Color(0x00000000);
}

class _FlameSim {
  _FlameSim(this.random);

  final math.Random random;
  final flames = <_Particle>[];
  final sparks = <_Particle>[];
  double _flameDebt = 0, _sparkDebt = 0, time = 0;

  void step(double dt, double level, {required bool reward, required bool active}) {
    time += dt;
    double r() => random.nextDouble();
    // Higher focus: more, larger, faster, longer-lived and hotter tongues of
    // flame. A small, cool flame keeps burning at zero so it never goes out.
    final intensity = active ? level : level * 0.3;
    _flameDebt += dt * (40 + 160 * intensity);
    while (_flameDebt >= 1) {
      _flameDebt -= 1;
      final spread = 0.04 + 0.11 * intensity;
      flames.add(
        _Particle(
          0.5 + (r() - 0.5) * 2 * spread,
          0.14,
          (r() - 0.5) * 0.04,
          0.1 + 0.3 * intensity + r() * 0.08,
          0.45 + 0.7 * intensity + r() * 0.25,
          0.045 + 0.055 * intensity + r() * 0.02,
          r() * 100,
          hue: 0.14 + 0.26 * (1 - intensity),
        ),
      );
    }
    if (reward) {
      _sparkDebt += dt * (5 + 12 * level);
      while (_sparkDebt >= 1) {
        _sparkDebt -= 1;
        sparks.add(
          _Particle(
            0.5 + (r() - 0.5) * 0.16,
            0.25 + r() * 0.2,
            (r() - 0.5) * 0.1,
            0.3 + r() * 0.3,
            1.4 + r() * 1.2,
            0.006 + r() * 0.005,
            r() * 100,
          ),
        );
      }
    }
    for (final p in flames) {
      p.age += dt;
      // Buoyant, drawn to the centre line, with a gentle sway.
      p.vy += 0.12 * dt;
      p.vx += (0.5 - p.x) * 1.2 * dt + math.sin(time * 2.5 + p.seed) * 0.03 * dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
    }
    for (final p in sparks) {
      p.age += dt;
      p.vy -= 0.06 * dt;
      p.x += (p.vx + math.sin(time * 2 + p.seed) * 0.05) * dt;
      p.y += p.vy * dt;
    }
    flames.removeWhere((p) => p.age >= p.life);
    sparks.removeWhere((p) => p.age >= p.life || p.y > 1.05);
  }
}

class _FlamePainter extends CustomPainter {
  _FlamePainter(this.view, {required Listenable repaint}) : super(repaint: repaint);

  final _FocusVisualViewState view;

  @override
  void paint(Canvas canvas, Size size) {
    final sim = view._flame;
    final l = view._shown;
    final d = view._dim;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D0B14), Color(0xFF1C130F)],
        ).createShader(rect),
    );
    final scale = math.min(size.width, size.height * 0.95);
    Offset at(double x, double y) => Offset(size.width / 2 + (x - 0.5) * scale, size.height * (1 - 0.95 * y));
    final base = at(0.5, 0.14);
    // The fire lights its surroundings more as it grows.
    final glowCenter = base.translate(0, -scale * 0.18);
    final glow = scale * (0.4 + 0.5 * l);
    canvas.drawCircle(
      glowCenter,
      glow,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFF8A2A).withValues(alpha: (0.12 + 0.3 * l) * (1 - 0.7 * d)),
            const Color(0x00FF8A2A),
          ],
        ).createShader(Rect.fromCircle(center: glowCenter, radius: glow)),
    );
    // Logs.
    final log = Paint()..color = const Color(0xFF3B2619);
    for (final angle in const [-0.2, 0.2]) {
      canvas.save();
      canvas.translate(base.dx, base.dy + scale * 0.04);
      canvas.rotate(angle);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: scale * 0.4, height: scale * 0.055),
          Radius.circular(scale * 0.03),
        ),
        log,
      );
      canvas.restore();
    }
    // Tongues of flame, additive and softened together so they read as one
    // fire rather than dots.
    // More particles overlap in a bigger fire: fainter each, so it brightens
    // without burning out to white.
    final alpha = (1 - 0.6 * d) * (0.5 - 0.22 * l);
    final paint = Paint()..blendMode = BlendMode.plus;
    final blur = math.max(2.0, scale * 0.025);
    canvas.saveLayer(rect, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur));
    for (final p in sim.flames) {
      final t = p.progress;
      paint.color = _fireColor(p.hue + (1 - p.hue) * t, alpha);
      canvas.drawCircle(at(p.x, p.y), scale * p.size * (1 - 0.65 * t), paint);
    }
    canvas.restore();
    for (final p in sim.sparks) {
      paint.color = _fireColor(0.1 + 0.75 * p.progress, 1 - 0.6 * d);
      canvas.drawCircle(at(p.x, p.y), math.max(1.2, scale * p.size), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FlamePainter old) => true;
}

class _Star {
  _Star(this.x, this.y, this.size, this.depth);

  double x, y;
  final double size;

  /// 0.3–1: nearer stars are brighter and stream past faster.
  final double depth;
}

class _RocketSim {
  _RocketSim(this.random) {
    for (var i = 0; i < 90; i++) {
      stars.add(
        _Star(
          random.nextDouble(),
          random.nextDouble(),
          0.6 + random.nextDouble() * 1.2,
          0.3 + random.nextDouble() * 0.7,
        ),
      );
    }
  }

  final math.Random random;
  final stars = <_Star>[];
  final exhaust = <_Particle>[];
  double time = 0, _debt = 0;

  void step(double dt, double level, {required bool active}) {
    time += dt;
    double r() => random.nextDouble();
    // Stars stream past in proportion to focus, so effort shows at once.
    final flow = active ? 0.04 + 0.6 * level : 0.02;
    for (final s in stars) {
      s.y += flow * s.depth * dt;
      if (s.y > 1) {
        s.y -= 1;
        s.x = r();
      }
    }
    final intensity = active ? level : level * 0.3;
    _debt += dt * (40 + 140 * intensity);
    while (_debt >= 1) {
      _debt -= 1;
      exhaust.add(
        _Particle(
          (r() - 0.5) * 0.15,
          0,
          (r() - 0.5) * 0.25,
          -(0.6 + 1.6 * intensity + r() * 0.4),
          0.18 + 0.3 * intensity + r() * 0.08,
          0.12 + 0.12 * intensity,
          r() * 100,
          hue: 0.1 + 0.25 * (1 - intensity),
        ),
      );
    }
    for (final p in exhaust) {
      p.age += dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
    }
    exhaust.removeWhere((p) => p.age >= p.life);
  }
}

class _RocketPainter extends CustomPainter {
  _RocketPainter(this.view, {required Listenable repaint}) : super(repaint: repaint);

  final _FocusVisualViewState view;

  @override
  void paint(Canvas canvas, Size size) {
    final sim = view._rocket;
    final l = view._shown;
    final d = view._dim;
    final rect = Offset.zero & size;
    // The sky darkens from dusk to space as the altitude builds over a session.
    final space = (view._altitude / 3000).clamp(0.0, 1.0);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(const Color(0xFF141A3C), const Color(0xFF05050F), space)!,
            Color.lerp(const Color(0xFF3B2F6E), const Color(0xFF0C0B24), space)!,
          ],
        ).createShader(rect),
    );
    // Stars, drawn as streaks that lengthen with speed.
    final starPaint = Paint()..strokeCap = StrokeCap.round;
    final streak = (0.003 + 0.035 * l * (1 - d)) * size.height;
    for (final s in sim.stars) {
      final p = Offset(s.x * size.width, s.y * size.height);
      starPaint
        ..color = Colors.white.withValues(alpha: (0.15 + 0.45 * s.depth) * (1 - 0.5 * d))
        ..strokeWidth = s.size;
      canvas.drawLine(p, p.translate(0, -streak * s.depth), starPaint);
    }

    // The rocket's height in the frame follows the score; the dashed line marks
    // the target.
    final unit = math.min(size.width / 5, size.height / 7.5);
    final low = size.height - 2.0 * unit, high = 1.6 * unit;
    double heightOf(double v) => low + (high - low) * v.clamp(0.0, 1.0);
    final targetY = heightOf(view._target);
    final dash = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 1.2;
    for (var x = 8.0; x < size.width - 8; x += 12) {
      canvas.drawLine(Offset(x, targetY), Offset(math.min(x + 6, size.width - 8), targetY), dash);
    }
    final label = TextPainter(
      text: const TextSpan(
        text: 'target',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0x99FFFFFF)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(size.width - label.width - 10, targetY - label.height - 2));

    final bob = math.sin(sim.time * 1.6) * unit * 0.05;
    final center = Offset(size.width / 2, heightOf(l) + bob);
    final nozzle = center.translate(0, unit * 0.95);

    final alpha = 1 - 0.6 * d;
    final paint = Paint()..blendMode = BlendMode.plus;
    final blur = math.max(1.5, unit * 0.12);
    canvas.saveLayer(rect, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur));
    for (final p in sim.exhaust) {
      final t = p.progress;
      paint.color = _fireColor(p.hue + (1 - p.hue) * t, alpha * (0.55 - 0.25 * l));
      canvas.drawCircle(nozzle.translate(p.x * unit, -p.y * unit * 2), unit * p.size * (1 + 1.5 * t), paint);
    }
    canvas.restore();

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(math.sin(sim.time * 0.9) * 0.03);
    final fin = Paint()..color = const Color(0xFF4F39F6);
    for (final side in const [-1.0, 1.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(side * unit * 0.3, unit * 0.2)
          ..quadraticBezierTo(side * unit * 0.72, unit * 0.55, side * unit * 0.68, unit * 1.0)
          ..lineTo(side * unit * 0.26, unit * 0.82)
          ..close(),
        fin,
      );
    }
    final body = Path()
      ..moveTo(0, -unit * 1.15)
      ..cubicTo(unit * 0.42, -unit * 0.8, unit * 0.4, unit * 0.2, unit * 0.27, unit * 0.9)
      ..lineTo(-unit * 0.27, unit * 0.9)
      ..cubicTo(-unit * 0.4, unit * 0.2, -unit * 0.42, -unit * 0.8, 0, -unit * 1.15)
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFC9CCDA), Color(0xFFF6F7FB), Color(0xFFB9BDCE)],
          stops: [0, 0.45, 1],
        ).createShader(Rect.fromLTRB(-unit * 0.42, -unit * 1.15, unit * 0.42, unit * 0.9)),
    );
    canvas.save();
    canvas.clipPath(body);
    canvas.drawRect(Rect.fromLTRB(-unit, -unit * 1.3, unit, -unit * 0.6), fin);
    canvas.restore();
    canvas.drawRect(
      Rect.fromLTRB(-unit * 0.04, unit * 0.2, unit * 0.04, unit * 0.9),
      Paint()..color = const Color(0xFF4F39F6),
    );
    final window = Offset(0, -unit * 0.18);
    canvas.drawCircle(window, unit * 0.17, Paint()..color = const Color(0xFF1B2140));
    canvas.drawCircle(
      window.translate(-unit * 0.05, -unit * 0.05),
      unit * 0.05,
      Paint()..color = const Color(0x8899AAFF),
    );
    canvas.drawCircle(
      window,
      unit * 0.17,
      Paint()
        ..color = const Color(0xFF8E96BC)
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * 0.05,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RocketPainter old) => true;
}
