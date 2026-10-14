import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../oddball.dart';
import '../sound_calibration.dart';
import 'number_field.dart';
import 'saved_runs.dart';

const _ink = Color(0xFF111216);
const _muted = Color(0xFF69707D);
const _line = Color(0xFFD9DCE3);
const _good = Color(0xFF0F7A3C);
const _warn = Color(0xFF7A4B00);
const _tabular = [FontFeature.tabularFigures()];

/// Walks through measuring the session's chosen output with a sound level
/// meter, so the oddball tones can be set in dB SPL.
Future<void> showSoundCalibration(BuildContext context, OddballSession session) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => SoundCalibrationDialog(session: session),
);

/// Three steps: get the meter and the Mac volume ready, read each tone at one
/// level, then add the levels to be used and check each on the meter. Readings
/// at those levels refine the calibration, so a level that reads off is right
/// the next time it plays.
class SoundCalibrationDialog extends StatefulWidget {
  const SoundCalibrationDialog({super.key, required this.session});

  final OddballSession session;

  @override
  State<SoundCalibrationDialog> createState() => _SoundCalibrationDialogState();
}

class _SoundCalibrationDialogState extends State<SoundCalibrationDialog> {
  OddballSession get session => widget.session;

  late final String _device = session.outputName ?? 'System output';
  late final SoundCalibration? _saved = session.calibrations[_device];
  late SoundCalibration _cal = _saved ?? _fresh();
  late final List<double> _tones = [session.settings.lowHz, session.settings.highHz];

  static const _stepTitles = ['Get ready', 'Measure each tone', 'Set your levels'];
  int _step = 0;

  /// The first reading's level for each tone, dB FS.
  late final Map<double, double> _reference = {
    for (final hz in _tones) hz: _cal.points.where((p) => p.hz == hz).firstOrNull?.dbfs ?? -30,
  };

  /// The tone playing, by the key of the row that started it.
  String? _playing;

  /// The level each row last played, dB FS; a reading is taken against it.
  final _played = <String, double>{};
  final _readings = <String, TextEditingController>{};

  /// This session's meter readings at each (level, tone).
  final _checks = <(double, double), double>{};
  double _newLevel = 70;
  String? _error;
  bool _saving = false;
  Timer? _volumePoll;

  SoundCalibration _fresh() => SoundCalibration(device: _device, date: DateTime.now());

  @override
  void initState() {
    super.initState();
    _volumePoll = Timer.periodic(const Duration(seconds: 1), (_) => session.refreshVolume());
  }

  @override
  void dispose() {
    _volumePoll?.cancel();
    if (_playing != null) unawaited(session.stopSteadyTone());
    for (final c in _readings.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _reading(String key) => _readings.putIfAbsent(key, TextEditingController.new);

  /// Loudest both tones reach at this volume, dB SPL.
  double? get _loudest {
    if (!_tones.every(_cal.covers)) return null;
    return _tones.map((hz) => _cal.maxSpl(hz)!).reduce(math.min);
  }

  bool get _volumeMoved {
    final was = _cal.volume, now = session.volume;
    return _cal.points.isNotEmpty && was != null && now != null && (now - was).abs() > 0.005;
  }

  Future<void> _play(String key, double hz, double dbfs) async {
    try {
      await session.playSteadyTone(hz, dbfs);
      setState(() {
        _playing = key;
        _played[key] = dbfs;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _playing = null;
        _error = 'Could not play the tone: ${e is PlatformException ? e.message ?? e.code : e}';
      });
    }
  }

  Future<void> _stop() async {
    if (_playing == null) return;
    setState(() => _playing = null);
    await session.stopSteadyTone();
  }

  Future<void> _toggle(String key, double hz, double dbfs) async {
    if (_playing == key) return _stop();
    await _play(key, hz, dbfs);
  }

  /// Saves what the meter read for row [key]; returns the reading, or null if
  /// it was not taken.
  double? _record(String key, double hz) {
    final dbfs = _played[key];
    final spl = NumberStepper.parse(_reading(key).text);
    if (dbfs == null) {
      setState(() => _error = 'Play the tone first, then type what the meter reads.');
      return null;
    }
    if (spl == null || spl < 0 || spl > 140) {
      setState(() => _error = 'Type the meter\'s reading in dB SPL, for example 64.5.');
      return null;
    }
    setState(() {
      // The readings hold at the volume they were taken at.
      if (_cal.points.isEmpty) _cal = _cal.copyWith(volume: session.volume);
      _cal = _cal.withPoint(CalibrationPoint(hz: hz, dbfs: dbfs, spl: spl));
      _error = null;
    });
    return spl;
  }

  void _startOver() {
    unawaited(_stop());
    setState(() {
      _cal = _fresh();
      _checks.clear();
      _played.clear();
      for (final c in _readings.values) {
        c.clear();
      }
    });
  }

  Future<void> _remove() async {
    await _stop();
    await session.calibrations.remove(_device);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _save() async {
    await _stop();
    setState(() => _saving = true);
    await session.saveCalibration(_cal.copyWith(date: DateTime.now()));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _close() async {
    await _stop();
    if (mounted) Navigator.of(context).pop();
  }

  void _goTo(int step) {
    unawaited(_stop());
    setState(() {
      _step = step;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.graphic_eq_rounded, size: 20, color: _ink),
                    const SizedBox(width: 8),
                    const Text(
                      'Calibrate the sound level',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _device,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _StepIndicator(titles: _stepTitles, current: _step),
                const SizedBox(height: 16),
                if (_volumeMoved && _step > 0) ...[
                  _Banner(
                    text:
                        'The Mac volume is now ${OddballSession.percent(session.volume!)}, but the readings were '
                        'taken at ${OddballSession.percent(_cal.volume!)}.',
                    action: (
                      'Set back to ${OddballSession.percent(_cal.volume!)}',
                      () => session.setVolume(_cal.volume!),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Flexible(
                  child: SingleChildScrollView(
                    child: switch (_step) {
                      0 => _prepare(),
                      1 => _measure(),
                      _ => _levels(),
                    },
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(fontSize: 11.5, color: Color(0xFFB42318))),
                ],
                const SizedBox(height: 16),
                _buttons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buttons() {
    final covered = _tones.every(_cal.covers);
    final (String label, VoidCallback? next) = switch (_step) {
      0 => ('Next', () => _goTo(1)),
      1 => ('Next', covered ? () => _goTo(2) : null),
      _ => ('Save calibration', covered && !_saving ? _save : null),
    };
    return Row(
      children: [
        TextButton(onPressed: _close, child: const Text('Cancel')),
        const Spacer(),
        if (_step > 0) ...[
          OutlinedButton(
            onPressed: () => _goTo(_step - 1),
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              side: const BorderSide(color: _line),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('Back'),
          ),
          const SizedBox(width: 8),
        ],
        ElevatedButton(
          onPressed: next,
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: const Color(0xFF080615),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFF2F2F5),
            disabledForegroundColor: const Color(0xFF9CA3AF),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Step 1: get ready.

  Widget _prepare() {
    final volume = session.volume;
    final saved = _saved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Body(
          'The app sets each tone\'s digital level, but how loud it is at the ear depends on the '
          'headphones, how they sit and the Mac volume. Measuring each tone once with a sound level '
          'meter ties these together, so you can then choose levels in dB SPL.',
        ),
        const SizedBox(height: 14),
        _Numbered(
          n: 1,
          title: 'Tones play through $_device.',
          detail:
              'Each output keeps its own calibration. For another one, close this and choose it under '
              '"Play tones through".',
        ),
        _Numbered(
          n: 2,
          title: 'Set the Mac volume to where it will stay for testing.',
          detail: volume == null
              ? 'The app cannot read this output\'s volume, so leave it unchanged after calibrating.'
              : 'It is at ${OddballSession.percent(volume)} now. Levels only hold at the volume they were '
                    'measured at; the app warns you if it changes. Somewhere around 50–75% leaves room both ways.',
        ),
        const _Numbered(
          n: 3,
          title: 'Put the meter\'s microphone where the ear would be.',
          detail:
              'Against the ear cup\'s speaker, or in a coupler or artificial ear if you have one, in a quiet room. '
              'Keep it in the same place for every reading.',
        ),
        const _Numbered(
          n: 4,
          title: 'Set the meter to C or Z weighting and slow response.',
          detail:
              'A phone app (such as NIOSH SLM) gives a rough calibration; use a Class 1 or 2 meter for '
              'levels you will report.',
        ),
        if (saved != null) ...[
          const SizedBox(height: 6),
          _Banner(
            text:
                'Already calibrated ${RunChecklist.when(saved.date)}'
                '${saved.volume == null ? '' : ' at ${OddballSession.percent(saved.volume!)} volume'}. '
                'Go on to check or add levels, or start over to measure from scratch.',
            neutral: true,
            action: ('Start over', _startOver),
            secondAction: ('Remove calibration', _remove),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Step 2: one reading per tone.

  Widget _measure() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Body(
          'Play each tone, let the meter settle, then type what it reads and save it. Start quiet: with the '
          'tone playing, the meter should read at least 10 dB more than the room does with no tone. If not, '
          'raise the level.',
        ),
        const SizedBox(height: 12),
        for (final hz in _tones) ...[_referenceCard(hz), const SizedBox(height: 10)],
      ],
    );
  }

  Widget _referenceCard(double hz) {
    final key = 'ref $hz';
    final level = _reference[hz]!;
    final covered = _cal.covers(hz);
    return _Card(
      children: [
        Row(
          children: [
            Text('${hz.round()} Hz tone', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            if (covered) const Icon(Icons.check_circle_rounded, size: 16, color: _good),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 140,
              child: _Captioned(
                caption: 'Play at',
                child: NumberStepper(
                  value: level,
                  min: OddballSettings.minDbfs,
                  max: 0,
                  step: 5,
                  unit: 'dB',
                  onChanged: (v) {
                    setState(() => _reference[hz] = v);
                    if (_playing == key) unawaited(_play(key, hz, v));
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            _PlayButton(playing: _playing == key, onPressed: () => _toggle(key, hz, level)),
            const SizedBox(width: 14),
            _ReadingField(controller: _reading(key), onSubmitted: () => _record(key, hz)),
            const SizedBox(width: 8),
            _SaveButton(onPressed: () => _record(key, hz)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          covered
              ? 'Saved. At this volume, ${hz.round()} Hz plays up to ${_cal.maxSpl(hz)!.floor()} dB SPL.'
              : '0 dB is the loudest the app plays. −30 dB is a safe start.',
          style: TextStyle(fontSize: 11, color: covered ? _good : _muted),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Step 3: the levels to be used, each checked on the meter.

  Widget _levels() {
    final loudest = _loudest ?? OddballSettings.maxSpl;
    final top = math.max(OddballSettings.minSpl, math.min(OddballSettings.maxSpl, loudest.floorToDouble()));
    void add(double level) {
      if (level > loudest + 0.05) {
        setState(() => _error = 'At this volume the tones reach ${loudest.floor()} dB SPL at most.');
        return;
      }
      setState(() {
        _cal = _cal.withLevel(level);
        _error = null;
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Body(
          'Add the levels you will test at. Each tone plays at the level your readings predict: check the '
          'meter and save what it reads. If it is more than 1 dB off, the calibration corrects itself, so play '
          'it again to confirm.',
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SizedBox(
              width: 150,
              child: _Captioned(
                caption: 'Level',
                child: NumberStepper(
                  value: math.min(_newLevel, top),
                  min: OddballSettings.minSpl,
                  max: top,
                  step: 1,
                  unit: 'dB SPL',
                  onChanged: (v) => setState(() => _newLevel = v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 34,
              child: OutlinedButton.icon(
                onPressed: () => add(math.min(_newLevel, top)),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add level', style: TextStyle(fontWeight: FontWeight.w800)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _ink,
                  side: const BorderSide(color: _line),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final level in const [50.0, 60.0, 70.0, 80.0])
                    if (!_cal.levels.contains(level) && level <= loudest)
                      ActionChip(
                        label: Text('+ ${level.round()}'),
                        onPressed: () => add(level),
                        labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                        visualDensity: VisualDensity.compact,
                      ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'At this volume the tones reach up to ${loudest.floor()} dB SPL.',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
        const SizedBox(height: 12),
        if (_cal.levels.isEmpty)
          const _Body('No levels yet. You can also save without any and type levels in the test panel.')
        else
          for (final level in _cal.levels.reversed) ...[_levelCard(level), const SizedBox(height: 10)],
      ],
    );
  }

  Widget _levelCard(double level) {
    return _Card(
      children: [
        Row(
          children: [
            Text('${formatDb(level)} dB SPL', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            if (level > OddballSettings.loudSpl) ...[
              const SizedBox(width: 8),
              const _Tag(text: 'Loud', color: _warn, background: Color(0xFFFFF7E6)),
            ],
            const Spacer(),
            IconButton(
              tooltip: 'Remove this level',
              onPressed: () => setState(() => _cal = _cal.withoutLevel(level)),
              icon: const Icon(Icons.delete_outline_rounded, size: 17),
              visualDensity: VisualDensity.compact,
              color: _muted,
            ),
          ],
        ),
        for (final hz in _tones) _levelLine(level, hz),
      ],
    );
  }

  Widget _levelLine(double level, double hz) {
    final key = 'level $level $hz';
    final dbfs = _cal.dbfsFor(hz, level)!;
    final reachable = dbfs <= 0.05;
    final reading = _checks[(level, hz)];
    final Widget status;
    if (!reachable) {
      status = Text(
        'Too loud for this output at this volume',
        style: const TextStyle(fontSize: 11, color: _warn),
      );
    } else if (reading == null) {
      status = const Text('Not checked yet', style: TextStyle(fontSize: 11, color: _muted));
    } else if ((reading - level).abs() <= 1) {
      status = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_rounded, size: 15, color: _good),
          const SizedBox(width: 4),
          Flexible(
            child: Text('Read ${formatDb(reading)}: within 1 dB', style: const TextStyle(fontSize: 11, color: _good)),
          ),
        ],
      );
    } else {
      status = Text(
        'Read ${formatDb(reading)}: corrected, play again to check',
        style: const TextStyle(fontSize: 11, color: _warn),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text('${hz.round()} Hz', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          _PlayButton(
            playing: _playing == key,
            onPressed: reachable ? () => _toggle(key, hz, dbfs) : null,
          ),
          const SizedBox(width: 10),
          _ReadingField(controller: _reading(key), onSubmitted: () => _check(key, level, hz)),
          const SizedBox(width: 6),
          _SaveButton(onPressed: reachable ? () => _check(key, level, hz) : null),
          const SizedBox(width: 10),
          Expanded(child: status),
        ],
      ),
    );
  }

  void _check(String key, double level, double hz) {
    final spl = _record(key, hz);
    if (spl == null) return;
    // The next play of this row uses the corrected level.
    unawaited(_stop());
    setState(() => _checks[(level, hz)] = spl);
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.titles, required this.current});

  final List<String> titles;
  final int current;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < titles.length; i++) ...[
        if (i > 0) const Expanded(child: Divider(color: _line, indent: 8, endIndent: 8)),
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i <= current ? _ink : Colors.white,
            border: Border.all(color: i <= current ? _ink : _line),
          ),
          child: i < current
              ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
              : Text(
                  '${i + 1}',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: i == current ? Colors.white : _muted),
                ),
        ),
        const SizedBox(width: 6),
        Text(
          titles[i],
          style: TextStyle(
            fontSize: 12,
            fontWeight: i == current ? FontWeight.w800 : FontWeight.w500,
            color: i == current ? _ink : _muted,
          ),
        ),
      ],
    ],
  );
}

class _Numbered extends StatelessWidget {
  const _Numbered({required this.n, required this.title, required this.detail});

  final int n;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Color(0xFFF1F2F5), shape: BoxShape.circle),
          child: Text('$n', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _ink)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink)),
              const SizedBox(height: 2),
              Text(detail, style: const TextStyle(fontSize: 11.5, color: _muted, height: 1.35)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 12, color: _muted, height: 1.4));
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _line),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

class _Captioned extends StatelessWidget {
  const _Captioned({required this.caption, required this.child});

  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(caption, style: const TextStyle(fontSize: 11, color: _muted)),
      const SizedBox(height: 4),
      child,
    ],
  );
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    width: 84,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 16),
      label: Text(playing ? 'Stop' : 'Play', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
      style: OutlinedButton.styleFrom(
        foregroundColor: playing ? Colors.white : _ink,
        backgroundColor: playing ? _ink : null,
        side: BorderSide(color: playing ? _ink : _line),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
  );
}

/// "Meter reads [ ] dB SPL".
class _ReadingField extends StatelessWidget {
  const _ReadingField({required this.controller, required this.onSubmitted});

  final TextEditingController controller;
  final VoidCallback onSubmitted;

  static const hint = '—';

  @override
  Widget build(BuildContext context) => _Captioned(
    caption: 'Meter reads',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          height: 34,
          child: TextField(
            controller: controller,
            onSubmitted: (_) => onSubmitted(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: _tabular),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: _line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(7),
                borderSide: const BorderSide(color: _ink),
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        const Text('dB SPL', style: TextStyle(fontSize: 11, color: _muted)),
      ],
    ),
  );
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: const Color(0xFFF1F2F5),
        foregroundColor: _ink,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: const Text('Save reading', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color, required this.background});

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(9)),
    child: Text(text, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color)),
  );
}

/// A note with up to two buttons; amber unless [neutral].
class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.action, this.secondAction, this.neutral = false});

  final String text;
  final (String, VoidCallback)? action;
  final (String, VoidCallback)? secondAction;
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final fg = neutral ? _ink : _warn;
    Widget button((String, VoidCallback) a) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        height: 28,
        child: OutlinedButton(
          onPressed: a.$2,
          style: OutlinedButton.styleFrom(
            foregroundColor: fg,
            side: BorderSide(color: neutral ? _line : const Color(0xFFE2B865)),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          ),
          child: Text(a.$1, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
        ),
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: neutral ? const Color(0xFFF7F7F8) : const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: neutral ? _line : const Color(0xFFF3D9A4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(fontSize: 11.5, color: fg, height: 1.35)),
          if (action != null || secondAction != null) ...[
            const SizedBox(height: 8),
            Row(children: [if (action != null) button(action!), if (secondAction != null) button(secondAction!)]),
          ],
        ],
      ),
    );
  }
}
