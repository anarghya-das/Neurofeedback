import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);
const _pair = Color(0xFF4F39F6);

/// An ⓘ button that explains the channel choices ("montages"): what each
/// channel measures against, and why a cup's top-minus-bottom pair suits the
/// P300. Put it beside a channel picker.
class MontageInfoButton extends StatelessWidget {
  const MontageInfoButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'What these channel choices mean',
    visualDensity: VisualDensity.compact,
    iconSize: 18,
    color: _muted,
    icon: const Icon(Icons.info_outline_rounded),
    onPressed: () => showDialog<void>(context: context, builder: (_) => const _MontageDialog()),
  );
}

class _MontageDialog extends StatelessWidget {
  const _MontageDialog();

  @override
  Widget build(BuildContext context) {
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink),
      ),
    );
    Widget para(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: const TextStyle(fontSize: 12, color: _ink, height: 1.45)),
    );
    Widget option(String name, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$name  ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            TextSpan(text: text),
          ],
        ),
        style: const TextStyle(fontSize: 12, color: _ink, height: 1.45),
      ),
    );

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 10, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Channels and montages',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    para(
                      'An EEG channel is always a voltage difference between two points. The MW75 records each '
                      'channel against the reference electrode (Ref), low on the left cushion. The DRL electrodes '
                      'on the right cushion cancel noise common to the whole head and are not recorded. A '
                      '"montage" is the choice of which differences you look at.',
                    ),
                    const SizedBox(height: 6),
                    const SizedBox(height: 190, child: _CupsDiagram()),
                    const SizedBox(height: 4),
                    const Text(
                      'Positions as Research Kit draws the cushions. Purple: the top − bottom pairs.',
                      style: TextStyle(fontSize: 11, color: _muted),
                    ),
                    heading('The choices'),
                    option(
                      'All EEG channels.',
                      'The average of Ch1–Ch12, each against Ref. Averaging lowers random noise, so this is a '
                          'good choice for band power, the spectrum and the alpha test. It can blur responses '
                          'that point opposite ways on different electrodes.',
                    ),
                    option(
                      'Left cup (Ch1–6).',
                      'These electrodes sit next to Ref, so each channel is a short, local difference: small '
                          'signals, but little pickup from the rest of the head.',
                    ),
                    option(
                      'Right cup (Ch7–12).',
                      'Right-ear electrodes against the left-ear Ref: a difference across the head. Activity '
                          'that is about equal on both sides, like much of the P300, largely cancels.',
                    ),
                    option('One channel (Ch1–Ch12).', 'That electrode against Ref, nothing averaged.'),
                    option(
                      'Top − bottom (oddball test only).',
                      'A cup\'s top electrode minus the one directly opposite it at the bottom: Ch2 − Ch5 on '
                          'the left, Ch8 − Ch11 on the right; "Both cups" averages the two. Ref cancels out, so '
                          'this is the voltage between the top and bottom of the cushion. The P300 is strongest '
                          'on top of the head and fades towards the jaw, so this vertical difference catches it, '
                          'while noise both electrodes share (mains hum, movement) cancels. Around-the-ear EEG '
                          'studies (cEEGrid) record the P300 best on pairs like this: vertical, as far apart as '
                          'possible. It is the default for the oddball test.',
                    ),
                    heading('Choose before you look'),
                    para(
                      'Each view gets its own p-value. Picking whichever channel looks best after a run '
                      'overstates the evidence: with 18 views to pick from, one will often reach p < 0.05 by chance. Use the '
                      'default, or decide on a view before the run.',
                    ),
                    heading('A caveat'),
                    para(
                      'Top and bottom assume Research Kit draws the cushions the right way up on the head. If '
                      'not, a top − bottom response simply flips sign; the rare-versus-standard test checks for '
                      'a difference either way.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Both cushions with their sensors, the top − bottom pairs joined.
class _CupsDiagram extends StatelessWidget {
  const _CupsDiagram();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(
        child: _Cup(
          title: 'Left cup',
          sensors: Mw75Montage.leftCup,
          pair: (Mw75Montage.leftTop, Mw75Montage.leftBottom),
        ),
      ),
      const SizedBox(width: 12),
      const Expanded(
        child: _Cup(
          title: 'Right cup',
          sensors: Mw75Montage.rightCup,
          pair: (Mw75Montage.rightTop, Mw75Montage.rightBottom),
        ),
      ),
    ],
  );
}

class _Cup extends StatelessWidget {
  const _Cup({required this.title, required this.sensors, required this.pair});

  final String title;
  final List<String> sensors;

  /// 0-based channel indices of the top and bottom electrode.
  final (int, int) pair;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: CustomPaint(painter: _CupPainter(sensors, pair), size: Size.infinite),
      ),
    ],
  );
}

class _CupPainter extends CustomPainter {
  _CupPainter(this.sensors, this.pair);

  final List<String> sensors;
  final (int, int) pair;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // An upright oval like the cushion, with room for the labels around it.
    final ry = size.height / 2 - 12;
    final rx = math.min(ry * 0.7, size.width / 2 - 24);
    canvas.drawOval(
      Rect.fromCenter(center: center, width: rx * 2, height: ry * 2),
      Paint()
        ..color = const Color(0xFFF1F2F5)
        ..style = PaintingStyle.fill,
    );
    canvas.drawOval(
      Rect.fromCenter(center: center, width: rx * 2, height: ry * 2),
      Paint()
        ..color = _line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final topLabel = '${pair.$1 + 1}', bottomLabel = '${pair.$2 + 1}';
    Offset at(int k) {
      // Eight positions 45° apart, clockwise from just right of the top.
      final angle = -math.pi / 2 + math.pi / 8 + k * math.pi / 4;
      return center + Offset(math.cos(angle) * rx, math.sin(angle) * ry);
    }

    final top = at(sensors.indexOf(topLabel));
    final bottom = at(sensors.indexOf(bottomLabel));
    canvas.drawLine(
      top,
      bottom,
      Paint()
        ..color = _pair.withValues(alpha: 0.5)
        ..strokeWidth = 2,
    );
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (var k = 0; k < sensors.length; k++) {
      final s = sensors[k];
      final inPair = s == topLabel || s == bottomLabel;
      final isChannel = int.tryParse(s) != null;
      final label = switch (s) {
        'R' => 'Ref',
        'D' => 'DRL',
        _ => 'Ch$s',
      };
      final p = at(k);
      final fill = inPair ? _pair : (isChannel ? Colors.white : const Color(0xFFE4E6EB));
      text.text = TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: inPair ? FontWeight.w800 : FontWeight.w600,
          color: inPair ? Colors.white : (isChannel ? _ink : _muted),
        ),
      );
      text.layout();
      final pill = RRect.fromRectAndRadius(
        Rect.fromCenter(center: p, width: text.width + 12, height: text.height + 6),
        const Radius.circular(10),
      );
      canvas.drawRRect(pill, Paint()..color = fill);
      if (!inPair) {
        canvas.drawRRect(
          pill,
          Paint()
            ..color = _line
            ..style = PaintingStyle.stroke,
        );
      }
      text.paint(canvas, p - Offset(text.width / 2, text.height / 2));
    }
    // Top and bottom marks.
    text.text = const TextSpan(
      text: 'top',
      style: TextStyle(fontSize: 9.5, color: _muted),
    );
    text.layout();
    text.paint(canvas, center + Offset(-text.width / 2, -ry * 0.62));
    text.text = const TextSpan(
      text: 'bottom',
      style: TextStyle(fontSize: 9.5, color: _muted),
    );
    text.layout();
    text.paint(canvas, center + Offset(-text.width / 2, ry * 0.62 - text.height));
  }

  @override
  bool shouldRepaint(covariant _CupPainter old) => false;
}
