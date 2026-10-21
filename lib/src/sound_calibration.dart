import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A sound level meter's reading of a steady tone.
@immutable
class CalibrationPoint {
  const CalibrationPoint({required this.hz, required this.dbfs, required this.spl});

  final double hz;

  /// Level played, in dB relative to the loudest the app plays (0 dB FS).
  final double dbfs;

  /// What the meter read, dB SPL.
  final double spl;

  Map<String, Object?> toJson() => {'hz': hz, 'dbfs': dbfs, 'spl': spl};

  factory CalibrationPoint.fromJson(Map<String, Object?> j) => CalibrationPoint(
    hz: (j['hz'] as num).toDouble(),
    dbfs: (j['dbfs'] as num).toDouble(),
    spl: (j['spl'] as num).toDouble(),
  );
}

/// How loud one audio output plays each tone, measured with a sound level
/// meter at one macOS volume.
///
/// The app can only set a tone's digital level; what reaches the ear also
/// depends on the headphones, their fit and the Mac's volume. Meter readings
/// tie the two together for each tone frequency: between readings the level
/// is interpolated, and beyond them the output is taken to be linear (1 dB more
/// digital level, 1 dB more sound).
@immutable
class SoundCalibration {
  const SoundCalibration({
    required this.device,
    required this.date,
    this.volume,
    this.points = const [],
    this.levels = const [],
  });

  /// The audio output's name; ids change when a device reconnects.
  final String device;
  final DateTime date;

  /// The output's macOS volume (0–1) during the readings, or null if it has no
  /// volume the app can read. The readings only hold at this volume.
  final double? volume;
  final List<CalibrationPoint> points;

  /// Levels (dB SPL) checked with the meter, offered as quick picks.
  final List<double> levels;

  /// Readings closer than this (dB of digital level) to a new one at the same
  /// frequency are replaced by it.
  static const _sameLevel = 1.0;

  bool covers(double hz) => points.any((p) => p.hz == hz);

  /// Digital level (dB FS) that plays [hz] at [spl] dB SPL; above 0 when the
  /// output cannot play it that loud. Null without a reading for [hz].
  double? dbfsFor(double hz, double spl) {
    final p = _sorted(hz);
    if (p.isEmpty) return null;
    if (spl <= p.first.spl) return p.first.dbfs + spl - p.first.spl;
    if (spl >= p.last.spl) return p.last.dbfs + spl - p.last.spl;
    for (var i = 1; i < p.length; i++) {
      if (spl <= p[i].spl) {
        final a = p[i - 1], b = p[i];
        return a.dbfs + (b.dbfs - a.dbfs) * (spl - a.spl) / (b.spl - a.spl);
      }
    }
    return p.last.dbfs + spl - p.last.spl;
  }

  /// dB SPL of [hz] played at [dbfs]; the inverse of [dbfsFor].
  double? splFor(double hz, double dbfs) {
    final p = _sorted(hz);
    if (p.isEmpty) return null;
    if (dbfs <= p.first.dbfs) return p.first.spl + dbfs - p.first.dbfs;
    if (dbfs >= p.last.dbfs) return p.last.spl + dbfs - p.last.dbfs;
    for (var i = 1; i < p.length; i++) {
      if (dbfs <= p[i].dbfs) {
        final a = p[i - 1], b = p[i];
        return a.spl + (b.spl - a.spl) * (dbfs - a.dbfs) / (b.dbfs - a.dbfs);
      }
    }
    return p.last.spl + dbfs - p.last.dbfs;
  }

  /// Loudest [hz] can play, dB SPL.
  double? maxSpl(double hz) => splFor(hz, 0);

  /// Adds a reading, replacing any at the same frequency and nearly the same
  /// digital level (a re-measurement).
  SoundCalibration withPoint(CalibrationPoint point) => _copy(
    points: [
      for (final p in points)
        if (p.hz != point.hz || (p.dbfs - point.dbfs).abs() >= _sameLevel) p,
      point,
    ],
  );

  SoundCalibration withoutPointsAt(double hz) => _copy(points: [for (final p in points) if (p.hz != hz) p]);

  SoundCalibration withLevel(double spl) =>
      levels.contains(spl) ? this : _copy(levels: [...levels, spl]..sort());

  SoundCalibration withoutLevel(double spl) => _copy(levels: [for (final l in levels) if (l != spl) l]);

  SoundCalibration copyWith({DateTime? date, double? volume}) =>
      _copy(date: date ?? this.date, volume: volume ?? this.volume);

  SoundCalibration _copy({DateTime? date, double? volume, List<CalibrationPoint>? points, List<double>? levels}) =>
      SoundCalibration(
        device: device,
        date: date ?? this.date,
        volume: volume ?? this.volume,
        points: points ?? this.points,
        levels: levels ?? this.levels,
      );

  /// Readings at [hz] in order of level. Ordered by what was played, so the
  /// curve stays one-to-one even when two readings disagree a little.
  List<CalibrationPoint> _sorted(double hz) {
    final p = [for (final p in points) if (p.hz == hz) p]..sort((a, b) => a.dbfs.compareTo(b.dbfs));
    // Keep the measured level rising with the digital one.
    final out = <CalibrationPoint>[];
    for (final q in p) {
      if (out.isEmpty || q.spl > out.last.spl) out.add(q);
    }
    return out;
  }

  Map<String, Object?> toJson() => {
    'device': device,
    'date': date.toIso8601String(),
    'volume': volume,
    'points': [for (final p in points) p.toJson()],
    'levels': levels,
  };

  factory SoundCalibration.fromJson(Map<String, Object?> j) => SoundCalibration(
    device: j['device'] as String,
    date: DateTime.parse(j['date'] as String),
    volume: (j['volume'] as num?)?.toDouble(),
    points: [
      for (final p in (j['points'] as List? ?? const []).cast<Map<Object?, Object?>>())
        CalibrationPoint.fromJson(p.cast<String, Object?>()),
    ],
    levels: [for (final l in (j['levels'] as List? ?? const [])) (l as num).toDouble()],
  );
}

/// Sound calibrations by output name, kept in [file] when there is one.
class SoundCalibrations extends ChangeNotifier {
  SoundCalibrations({this.file});

  final File? file;
  final _byDevice = <String, SoundCalibration>{};

  SoundCalibration? operator [](String? device) => device == null ? null : _byDevice[device];

  Future<void> load() async {
    final file = this.file;
    if (file == null || !await file.exists()) return;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      for (final c in (json['outputs'] as List? ?? const []).cast<Map<Object?, Object?>>()) {
        final calibration = SoundCalibration.fromJson(c.cast<String, Object?>());
        _byDevice[calibration.device] = calibration;
      }
    } catch (e) {
      debugPrint('[sound] could not read ${file.path}: $e');
    }
    notifyListeners();
  }

  Future<void> save(SoundCalibration calibration) async {
    _byDevice[calibration.device] = calibration;
    notifyListeners();
    await _write();
  }

  Future<void> remove(String device) async {
    if (_byDevice.remove(device) == null) return;
    notifyListeners();
    await _write();
  }

  Future<void> _write() async {
    final file = this.file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'outputs': [for (final c in _byDevice.values) c.toJson()],
      }),
    );
  }
}

/// 0–1 of full scale for a level in dB FS.
double amplitudeForDbfs(double dbfs) => math.pow(10, dbfs / 20).toDouble();

/// dB FS for 0–1 of full scale.
double dbfsForAmplitude(double amplitude) => 20 * math.log(amplitude) / math.ln10;

/// "70", "72.5" or "−10" (with a true minus sign).
String formatDb(double db) {
  final rounded = (db * 10).round() / 10;
  final text = rounded == rounded.roundToDouble() ? rounded.abs().toStringAsFixed(0) : rounded.abs().toStringAsFixed(1);
  return rounded < 0 ? '−$text' : text;
}
