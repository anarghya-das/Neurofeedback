import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../protocol.dart';
import '../signal_quality.dart';

/// Colours from Neurable Research Kit (Tailwind v4 palette, converted to sRGB).
class _Rating {
  const _Rating(
    this.label,
    this.sensor,
    this.badgeBg,
    this.badgeText,
    this.badgeDot,
  );

  final String label;
  final Color sensor;
  final Color badgeBg;
  final Color badgeText;
  final Color badgeDot;

  static const best = _Rating(
    'Best',
    Color(0xFF155DFC),
    Color(0xFFEFF6FF),
    Color(0xFF193CB8),
    Color(0xFF155DFC),
  );
  static const good = _Rating(
    'Good',
    Color(0xFF00B8DB),
    Color(0xFFECFEFF),
    Color(0xFF005F78),
    Color(0xFF0092B8),
  );
  static const acceptable = _Rating(
    'Acceptable',
    Color(0xFFF0B100),
    Color(0xFFFEFCE8),
    Color(0xFF894B00),
    Color(0xFFD08700),
  );
  static const bad = _Rating(
    'Bad',
    Color(0xFFCA3500),
    Color(0xFFFFEDD4),
    Color(0xFF7E2A0C),
    Color(0xFFCA3500),
  );
  static const checking = _Rating(
    'Checking',
    Color(0xFF99A1AF),
    Color(0xFFF3F4F6),
    Color(0xFF364153),
    Color(0xFF6A7282),
  );

  static _Rating of(ContactQuality? q) => switch (q) {
    ContactQuality.best => best,
    ContactQuality.good => good,
    ContactQuality.acceptable => acceptable,
    ContactQuality.bad => bad,
    null => checking,
  };
}

/// Both ear cushions with every electrode coloured by its contact rating, a
/// per-cup summary and a legend, laid out like Research Kit's "EEG signal
/// quality" panel. Pass `quality: null` before the first report.
class EarCupQualityMap extends StatelessWidget {
  const EarCupQualityMap({
    super.key,
    required this.quality,
    required this.strictness,
  });

  final Mw75SignalQuality? quality;
  final QualityStrictness strictness;


  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final side in EarSide.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    children: [
                      _EarCup(side: side, quality: quality),
                      const SizedBox(height: 10),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _GeneralQualityBadge(
                          rating: _Rating.of(
                            sideQuality(quality, side, strictness),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        const _Legend(),
      ],
    );
  }
}

/// Electrodes in the order Research Kit places them, clockwise from the top
/// right of each cushion.
const _layout = {
  EarSide.left: Mw75Montage.leftCup,
  EarSide.right: Mw75Montage.rightCup,
};

ContactQuality? _ratingFor(String electrode, Mw75SignalQuality? q) {
  if (q == null) return null;
  return switch (electrode) {
    'R' => q.ref,
    'D' => q.drl,
    _ => q.channels[int.parse(electrode) - 1],
  };
}

String _spokenName(String electrode) => switch (electrode) {
  'R' => 'Reference',
  'D' => 'Driven right leg',
  _ => 'Channel $electrode',
};

class _EarCup extends StatelessWidget {
  const _EarCup({required this.side, required this.quality});

  final EarSide side;
  final Mw75SignalQuality? quality;

  // Research Kit's geometry (a 160 × 240 box, cushion layers scaled by 0.72 ×
  // 1.2, eight pills 45° apart on an ellipse), shrunk by [_fit] so both cups fit
  // side by side in a 344 px card column.
  static const _fit = 0.88;
  static const _width = 160.0 * _fit;
  static const _height = 240.0 * _fit;
  static const _scale = 0.72 * 1.2;
  static const _pillGap = 26 * 1.2 * _fit;
  static const _sensorBox = _pillGap + 8 * _fit;
  static const _outerW = _width * _scale;
  static const _outerH = _height * _scale;
  static const _ringW = _outerW + _pillGap;
  static const _ringH = _outerH + _pillGap;
  static const _innerW = _ringW - _sensorBox * 2;
  static const _innerH = _ringH - _sensorBox * 2;
  static const _orbitX = _ringW / 2 - _sensorBox / 2;
  static const _orbitY = _ringH / 2 - _sensorBox / 2;
  static const _pillH = _sensorBox - 2;
  static const _pillW = _pillH * 16 / 28;
  static const _radiusScale = 1.05;
  static const _extentW = 2 * (_orbitX * _radiusScale + _pillH / 2) + 2;
  static const _extentH = 2 * (_orbitY * _radiusScale + _pillH / 2) + 2;

  @override
  Widget build(BuildContext context) {
    final electrodes = _layout[side]!;
    return Column(
      children: [
        Text(
          side == EarSide.left ? 'Left' : 'Right',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF6A7282),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: _extentW,
          height: _extentH,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Container(
                width: _outerW,
                height: _outerH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_outerW),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFFF3F4F6), Color(0xFFF9FAFB)],
                  ),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0D000000),
                      blurRadius: 2,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
              Container(
                width: _ringW,
                height: _ringH,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_ringW),
                  color: const Color(0xFF99A1AF).withValues(alpha: 0.15),
                ),
              ),
              Container(
                width: _innerW,
                height: _innerH,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_innerW),
                  color: const Color(0xFF101828).withValues(alpha: 0.05),
                ),
                child: Text(
                  side == EarSide.left ? 'L' : 'R',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFD1D5DC),
                  ),
                ),
              ),
              for (var k = 0; k < electrodes.length; k++)
                _pill(electrodes[k], k, electrodes.length),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pill(String electrode, int index, int count) {
    final step = 2 * math.pi / count;
    final angle = step * index - math.pi / 2 + step / 2;
    final c = math.cos(angle);
    final s = math.sin(angle);
    // Radius of the placement ellipse along this direction.
    final r =
        1 /
        math.sqrt(c * c / (_orbitX * _orbitX) + s * s / (_orbitY * _orbitY));
    final rating = _ratingFor(electrode, quality);
    final style = _Rating.of(rating);
    final name = _spokenName(electrode);
    return Transform.translate(
      offset: Offset(c * r * _radiusScale, s * r * _radiusScale),
      child: Transform.rotate(
        angle: angle + math.pi / 2,
        child: Tooltip(
          message: '$name: ${style.label.toLowerCase()}',
          child: Semantics(
            label: '$name contact ${style.label}',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: _pillW,
              height: _pillH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: style.sensor,
                borderRadius: BorderRadius.circular(_pillW),
              ),
              child: Transform.rotate(
                angle: -(angle + math.pi / 2),
                child: Text(
                  electrode,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GeneralQualityBadge extends StatelessWidget {
  const _GeneralQualityBadge({required this.rating});

  final _Rating rating;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: rating.badgeBg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: rating.badgeDot,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'General quality: ${rating.label}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: rating.badgeText,
          ),
        ),
      ],
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 12,
    runSpacing: 6,
    children: [
      for (final r in const [
        _Rating.best,
        _Rating.good,
        _Rating.acceptable,
        _Rating.bad,
      ])
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: r.sensor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              r.label,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF364153),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
    ],
  );
}

/// Research Kit's "Threshold strictness" picker.
class StrictnessPicker extends StatelessWidget {
  const StrictnessPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final QualityStrictness value;
  final ValueChanged<QualityStrictness> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<QualityStrictness>(
      tooltip: 'Threshold strictness',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final option in QualityStrictness.values)
          PopupMenuItem(
            value: option,
            child: Row(
              children: [
                Icon(
                  option == value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: option == value
                      ? const Color(0xFF155DFC)
                      : const Color(0xFF99A1AF),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      option.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      option.description,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6A7282),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFFD9DCE3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value.label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF364153),
                  ),
                ),
                Text(
                  value.description,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF99A1AF),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: Color(0xFF6A7282),
            ),
          ],
        ),
      ),
    );
  }
}
