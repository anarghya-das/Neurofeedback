import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class BandPowerBarChart extends StatefulWidget {
  final double delta;
  final double theta;
  final double alpha;
  final double beta;
  final double gamma;

  final double? baselineDelta;
  final double? baselineTheta;
  final double? baselineAlpha;
  final double? baselineBeta;
  final double? baselineGamma;

  const BandPowerBarChart({
    super.key,
    required this.delta,
    required this.theta,
    required this.alpha,
    required this.beta,
    required this.gamma,
    required this.baselineDelta,
    required this.baselineTheta,
    required this.baselineAlpha,
    required this.baselineBeta,
    required this.baselineGamma,
  });

  @override
  State<BandPowerBarChart> createState() => _BandPowerBarChartState();
}

class _BandPowerBarChartState extends State<BandPowerBarChart> {
  final List<bool> _enabledBands = [true, true, true, true, true];

  double _safe(double v) {
    if (v.isNaN || v.isInfinite || v <= 0) return 0.1;
    return v;
  }

  double _log10(double v) => math.log(v) / math.ln10;

  String _formatPower(double value) {
    if (value >= 100) return value.toStringAsFixed(1);
    if (value >= 10) return value.toStringAsFixed(2);
    if (value >= 1) return value.toStringAsFixed(3);
    if (value >= 0.1) return value.toStringAsFixed(4);
    if (value >= 0.01) return value.toStringAsFixed(5);
    return value.toStringAsExponential(2);
  }

  String _formatDelta(double? baseline, double current) {
    if (baseline == null || baseline <= 0) return 'Δ —';
    final diff = current - baseline;
    final sign = diff >= 0 ? '+' : '';
    return 'Δ $sign${diff.toStringAsFixed(3)}';
  }

  void _toggleBand(int index) {
    if (index < 0 || index >= _enabledBands.length) return;
    setState(() {
      _enabledBands[index] = !_enabledBands[index];
    });
  }

  Widget _bottomLabel(int index, String band, String hz) {
    final enabled = _enabledBands[index];

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _toggleBand(index),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              band,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: enabled
                    ? const Color(0xFF0B1F3A)
                    : const Color(0xFF9CA3AF),
                decoration: enabled
                    ? TextDecoration.none
                    : TextDecoration.lineThrough,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              enabled ? hz : 'OFF',
              style: TextStyle(
                fontSize: 11,
                color: enabled
                    ? const Color(0xFF0B1F3A)
                    : const Color(0xFF9CA3AF),
                fontWeight: enabled ? FontWeight.normal : FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _majorTickLabel(double value) {
    if ((value + 1.0).abs() < 0.001) return '0.1';
    if ((value - 0.0).abs() < 0.001) return '1';
    if ((value - 1.0).abs() < 0.001) return '10';
    if ((value - 2.0).abs() < 0.001) return '100';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final values = [
      _safe(widget.delta),
      _safe(widget.theta),
      _safe(widget.alpha),
      _safe(widget.beta),
      _safe(widget.gamma),
    ];

    final baselines = [
      widget.baselineDelta,
      widget.baselineTheta,
      widget.baselineAlpha,
      widget.baselineBeta,
      widget.baselineGamma,
    ];

    final logValues = values.map(_log10).toList();

    const double minLog = -1.0;
    const double maxLog = 2.0;

    final colors = <Color>[
      const Color(0xFFF45B5B),
      const Color(0xFFE5C100),
      const Color(0xFF4F9A84),
      const Color(0xFF5D80BD),
      const Color(0xFF9A72AE),
    ];

    final labels = <Map<String, String>>[
      {'band': 'DELTA', 'hz': '0.5–4Hz'},
      {'band': 'THETA', 'hz': '4–8Hz'},
      {'band': 'ALPHA', 'hz': '8–13Hz'},
      {'band': 'BETA', 'hz': '13–32Hz'},
      {'band': 'GAMMA', 'hz': '32–100Hz'},
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFBFC3C7), width: 1.2),
      ),
      padding: const EdgeInsets.fromLTRB(8, 10, 14, 12),
      child: BarChart(
        BarChartData(
          minY: minLog,
          maxY: maxLog,
          alignment: BarChartAlignment.spaceAround,
          groupsSpace: 12,
          barTouchData: BarTouchData(
            enabled: true,
            touchCallback: (event, response) {
              if (!event.isInterestedForInteractions) return;

              final group = response?.spot?.touchedBarGroup;
              if (group == null) return;

              if (event is FlTapUpEvent || event is FlLongPressEnd) {
                _toggleBand(group.x.toInt());
              }
            },
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final idx = group.x.toInt();
                final band = labels[idx]['band']!;
                final actualPower = values[idx];
                final baseline = baselines[idx];

                if (!_enabledBands[idx]) {
                  return BarTooltipItem(
                    '$band OFF\nTap again to show',
                    const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  );
                }

                return BarTooltipItem(
                  '$band\n'
                  '${_formatPower(actualPower)} (uV)²/Hz\n'
                  '${_formatDelta(baseline, actualPower)}',
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                );
              },
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: const Border(
              left: BorderSide(color: Colors.black, width: 1.2),
              bottom: BorderSide(color: Colors.black, width: 1.2),
              top: BorderSide.none,
              right: BorderSide.none,
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 0.1,
            getDrawingHorizontalLine: (value) {
              final isMajor =
                  (value - (-1)).abs() < 0.001 ||
                  (value - 0).abs() < 0.001 ||
                  (value - 1).abs() < 0.001 ||
                  (value - 2).abs() < 0.001;

              return FlLine(
                color: isMajor
                    ? const Color(0xFFB8B8B8)
                    : const Color(0xFFE8E8E8),
                strokeWidth: isMajor ? 1.0 : 0.5,
              );
            },
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              axisNameWidget: const SizedBox(
                width: 80,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 1,
                    child: Text(
                      'Power — (uV)² / Hz',
                      style: TextStyle(fontSize: 20, color: Color(0xFF0B1F3A)),
                    ),
                  ),
                ),
              ),
              axisNameSize: 80,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final label = _majorTickLabel(value);
                  if (label.isEmpty) return const SizedBox.shrink();
                  return SizedBox(
                    width: 46,
                    child: Text(
                      label,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF0B1F3A),
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              axisNameWidget: const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'EEG Power Bands',
                  style: TextStyle(fontSize: 16, color: Color(0xFF0B1F3A)),
                ),
              ),
              axisNameSize: 36,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 58,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= labels.length) {
                    return const SizedBox.shrink();
                  }
                  return _bottomLabel(i, labels[i]['band']!, labels[i]['hz']!);
                },
              ),
            ),
          ),
          barGroups: List.generate(values.length, (i) {
            final enabled = _enabledBands[i];
            final clampedTop = logValues[i].clamp(minLog, maxLog).toDouble();

            return BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  fromY: minLog,
                  toY: enabled ? clampedTop : maxLog,
                  width: 60,
                  color: enabled ? colors[i] : Colors.transparent,
                  borderRadius: BorderRadius.zero,
                  borderSide: enabled
                      ? BorderSide.none
                      : const BorderSide(color: Color(0xFFBFC3C7), width: 1.2),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }
}
