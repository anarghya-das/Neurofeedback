import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'headset.dart' show HeadsetLogEntry;
import 'lsl_eeg_outlet.dart';
import 'transport.dart';

enum MetricState { idle, connecting, running, stopping, error }

/// The headset's metrics session over Bluetooth Low Energy: the Focus score
/// (0–1, about once a second) and a 0–5 contact level per ear cup, both
/// computed by the headset itself.
///
/// Follows Neurable Research Kit 1.1.3's BLE "metrics" session. Research Kit
/// runs this instead of raw EEG, never alongside it. One deliberate difference:
/// on stop Research Kit also deletes the last session stored on the headset;
/// this driver does not delete anything.
class Mw75MetricSession extends ChangeNotifier {
  Mw75MetricSession({Mw75Transport? transport, this.streamName = 'MW75 Neuro Focus'})
    : _transport = transport ?? Mw75Transport();

  static const service = '00001100-D102-11E1-9B23-00025B00A5A5';
  static const commandCharacteristic = '00001101-D102-11E1-9B23-00025B00A5A5';
  static const responseCharacteristic = '00001102-D102-11E1-9B23-00025B00A5A5';
  static const eegCharacteristic = '00001105-D102-11E1-9B23-00025B00A5A6';

  static const _getClock = [0x09, 0x9A, 0x03, 0x32];
  static const _startSession = [0x09, 0x9A, 0x03, 0x35, 0x04];
  static const _stopSession = [0x09, 0x9A, 0x03, 0x36, 0xFF];

  /// Research Kit's "default population values": f32 0.16378, f32 0.40867,
  /// u16 20, 30, 10. Their meaning is not documented.
  static const _setCalibration = [
    0x09, 0x9A, 0x03, 0x7C, 0xE1, 0xB6, 0x27, 0x3E, 0x20, 0x3D, 0xD1, 0x3E, 0x14, 0x00, 0x1E, 0x00, 0x0A, 0x00,
  ];

  static const _commandTimeout = Duration(seconds: 3);

  final Mw75Transport _transport;

  /// LSL stream name for the Focus score; takes effect on the next start.
  String streamName;
  bool publishToLsl = true;

  MetricState _state = MetricState.idle;
  MetricState get state => _state;
  String statusText = 'Start Focus to get the headset’s focus score.';

  /// Latest Focus score, 0–1.
  double? focus;
  int? leftContact;
  int? rightContact;

  /// Per-cup contact messages received this session, to see how often the
  /// headset updates them.
  int contactMessages = 0;

  /// True while the headset has paused the session. It does this by itself when
  /// it is lifted off the head (session status `09 9A 03 82 02 …`), sends no
  /// scores while paused, and resumes (`82 01 …`) once it is back on.
  bool paused = false;
  int records = 0;
  final log = ListQueue<HeadsetLogEntry>();

  final _assembler = FocusRecordAssembler();
  _Waiter? _waiter;

  /// Set once start_session has been sent: from then on, any failure must still
  /// end the session, or the headset keeps it running and refuses the next start.
  bool _sessionRequested = false;
  LslEegOutlet? _outlet;
  StreamSubscription<BleNotification>? _notifications;
  StreamSubscription<void>? _disconnects;
  StreamSubscription<String>? _bleLogs;
  Timer? _watchdog;

  Future<void> start() async {
    if (_state == MetricState.connecting || _state == MetricState.running) return;
    _setState(MetricState.connecting, 'Connecting over Bluetooth Low Energy…');
    focus = null;
    leftContact = null;
    rightContact = null;
    records = 0;
    contactMessages = 0;
    paused = false;
    _assembler.reset();
    _sessionRequested = false;

    _notifications = _transport.bleNotifications.listen(_onNotification);
    _disconnects = _transport.bleDisconnected.listen((_) => _onDisconnected());
    _bleLogs = _transport.bleLogs.listen(_log);

    try {
      final link = await _transport.bleConnect(
        service: service,
        notify: const [responseCharacteristic, eegCharacteristic],
      );
      final subscribed = link.characteristics.entries.where((e) => e.value).map((e) => e.key.substring(4, 8));
      _log('Connected to ${link.name} over BLE; notifying: ${subscribed.join(', ')}');
      if (!link.characteristics.containsKey(commandCharacteristic)) {
        throw const _MetricFailure('The headset has no command characteristic. Is this an MW75 Neuro?');
      }

      _setStatus('Starting the focus session…');
      // Research Kit waits about a second after connecting before its first command.
      await Future<void>.delayed(const Duration(seconds: 1));

      if (await _send('get_clock', _getClock) != null) {
        await _send('update_clock', _updateClock(DateTime.now()));
      }
      if (!await _calibrateAndStart()) {
        // The headset refuses while a session is still running, for example one
        // left behind by an app that quit mid-session. End it and retry once.
        _log('The headset refused to start; ending any session still running and retrying once');
        await _send('stop_session', _stopSession, timeout: const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!await _calibrateAndStart()) {
          throw const _MetricFailure(
            'The headset refused to start Focus. If raw EEG is streaming, stop it first: '
            'the headset only starts Focus once raw mode is off.',
          );
        }
      }

      if (publishToLsl) {
        _outlet = LslEegOutlet.create(
          name: streamName,
          type: 'Focus',
          sourceId: 'mw75-focus-${link.identifier}',
          nominalRate: 1,
          extraDesc: const {'manufacturer': 'Neurable', 'description': 'Focus score 0-1 computed by the MW75 Neuro'},
          channels: const [LslChannel('focus', unit: 'unitless', type: 'MISC')],
        );
        _log('LSL outlet "$streamName" created');
      }

      _watchdog = Timer(const Duration(seconds: 15), () {
        if (_state == MetricState.running && records == 0) {
          _setStatus('No focus score yet. Put the headset on and keep still; the first score can take a while.');
        }
      });
      _setState(
        MetricState.running,
        publishToLsl ? 'Waiting for the first focus score. Publishing to LSL as "$streamName".' : 'Waiting for the first focus score.',
      );
    } catch (e) {
      final message = e is _MetricFailure ? e.message : _describe(e);
      _log('Start failed: $message');
      await _teardown(sendStop: _sessionRequested);
      _setState(MetricState.error, message);
    }
  }

  Future<void> stop() async {
    if (_state != MetricState.running && _state != MetricState.error) return;
    _setState(MetricState.stopping, 'Stopping…');
    await _teardown(sendStop: true);
    _setState(MetricState.idle, records == 0 ? 'Stopped. No focus scores arrived.' : 'Stopped after $records focus scores.');
  }

  @override
  void dispose() {
    unawaited(_teardown(sendStop: _state == MetricState.running));
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  void _onNotification(BleNotification n) {
    final b = n.bytes;
    if (b.length < 4 || b[0] != 0x09 || b[1] != 0x9A || b[2] != 0x03) return;
    final op = b[3];

    // Per-cup contact: 09 9A 03 E1 <left> <right>, each 0–5.
    if (op == 0xE1 && b.length >= 6) {
      contactMessages++;
      if (leftContact != b[4] || rightContact != b[5]) {
        leftContact = b[4];
        rightContact = b[5];
        notifyListeners();
      }
      return;
    }

    if (FocusRecordAssembler.isChunk(b)) {
      _onFocus(_assembler.add(b), n.time);
      return;
    }

    // Session status: 09 9A 03 82 <state> <session id:2> … — 01 running,
    // 02 paused (followed by the pause time).
    if (op == 0x82 && b.length >= 5 && (b[4] == 0x01 || b[4] == 0x02)) {
      final nowPaused = b[4] == 0x02;
      if (nowPaused != paused) {
        paused = nowPaused;
        _log(paused ? 'Headset paused the focus session (lifted off the head)' : 'Headset resumed the focus session');
        notifyListeners();
      }
      return;
    }

    if (op == 0x93 && b.length >= 5) {
      _log('Headset calibration profile ${b[4] == 1 ? 'available' : 'unavailable'}');
      return;
    }

    final waiter = _waiter;
    if (waiter != null && !waiter.completer.isCompleted && (op == waiter.op || b.length == 3)) {
      _log('← ${_hex(b)}  (${waiter.name})');
      waiter.completer.complete(b);
    } else {
      _log('← ${_hex(b)}');
    }
  }

  void _onFocus(FocusResult result, double time) {
    switch (result) {
      case FocusResult.pending:
        return;
      case FocusResult.outOfOrder:
        _log('Focus chunk out of order; waiting for the next record');
        return;
      case FocusResult.invalid:
        _log('Headset sent a non-numeric focus value; skipped');
        return;
      case FocusResult.ready:
        final value = _assembler.focus!;
        records++;
        focus = value;
        _outlet?.pushChunk([
          [value],
        ], [time]);
        if (records == 1) {
          _setStatus(publishToLsl ? 'Receiving focus scores. Publishing to LSL as "$streamName".' : 'Receiving focus scores.');
        }
        notifyListeners();
    }
  }

  void _onDisconnected() {
    _log('The headset closed the BLE connection');
    if (_state == MetricState.running || _state == MetricState.connecting) {
      unawaited(_teardown(sendStop: false));
      _setState(MetricState.error, 'The headset disconnected. Check that it is on and in range, then start again.');
    }
  }

  /// set_calibration, then start_session; true once the headset confirms the session.
  Future<bool> _calibrateAndStart() async {
    final calibration = await _send('set_calibration', _setCalibration);
    if (calibration == null || !_acknowledged(calibration)) {
      _log('set_calibration was not confirmed; continuing like Research Kit');
    }
    _sessionRequested = true;
    // Replies can take several seconds when the headset is busy.
    final started = await _send('start_session', _startSession, timeout: const Duration(seconds: 6));
    return started != null && _acknowledged(started);
  }

  Future<Uint8List?> _send(String name, List<int> bytes, {Duration timeout = _commandTimeout}) async {
    final waiter = _Waiter(name, bytes[3]);
    _waiter = waiter;
    _log('→ $name  ${_hex(bytes)}');
    try {
      await _transport.bleWrite(commandCharacteristic, bytes);
      return await waiter.completer.future.timeout(timeout);
    } on TimeoutException {
      _log('  $name: no reply');
      return null;
    } finally {
      if (identical(_waiter, waiter)) _waiter = null;
    }
  }

  static bool _acknowledged(Uint8List reply) => reply.length > 4 && reply[4] == 0xF1;

  /// 09 9A 03 31, Unix seconds (u32 LE), local offset from UTC in minutes (i16 LE).
  static List<int> _updateClock(DateTime now) {
    final payload = ByteData(6)
      ..setUint32(0, now.millisecondsSinceEpoch ~/ 1000, Endian.little)
      ..setInt16(4, now.timeZoneOffset.inMinutes, Endian.little);
    return [0x09, 0x9A, 0x03, 0x31, ...payload.buffer.asUint8List()];
  }

  Future<void> _teardown({required bool sendStop}) async {
    _watchdog?.cancel();
    _watchdog = null;
    if (sendStop) {
      final reply = await _send('stop_session', _stopSession);
      if (reply == null || !_acknowledged(reply)) _log('stop_session was not confirmed');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    try {
      await _transport.bleDisconnect();
    } catch (_) {}
    await _notifications?.cancel();
    await _disconnects?.cancel();
    await _bleLogs?.cancel();
    _notifications = null;
    _disconnects = null;
    _bleLogs = null;
    final waiter = _waiter;
    if (waiter != null && !waiter.completer.isCompleted) waiter.completer.completeError(TimeoutException('closed'));
    _waiter = null;
    _outlet?.close();
    _outlet = null;
  }

  void _setState(MetricState state, String status) {
    _state = state;
    statusText = status;
    _log(status);
    notifyListeners();
  }

  void _setStatus(String status) {
    statusText = status;
    notifyListeners();
  }

  void _log(String message) {
    log.add(HeadsetLogEntry(message));
    while (log.length > 500) {
      log.removeFirst();
    }
    if (kDebugMode) debugPrint('[metrics] $message');
  }

  static String _describe(Object e) => e is PlatformException
      ? e.message ?? e.code
      : e is MissingPluginException
          ? 'not available on this platform yet (no native driver)'
          : e.toString();

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

class _Waiter {
  _Waiter(this.name, this.op);

  final String name;
  final int op;
  final completer = Completer<Uint8List>();
}

class _MetricFailure implements Exception {
  const _MetricFailure(this.message);

  final String message;
}

enum FocusResult { pending, ready, outOfOrder, invalid }

/// Reassembles the headset's Focus record from BLE notifications.
///
/// Each notification is `09 9A 03 84 AA FC <payload length> <chunk index u16 LE>
/// <payload>`. Chunk 0 starts a record, each next index appends, anything else
/// discards the partial record. Once 128 bytes have arrived, the record's float
/// at byte 120 (little endian) is the Focus score, 0–1. Research Kit reads no
/// other part of the record.
class FocusRecordAssembler {
  static const recordSize = 128;
  static const focusOffset = 120;

  final _record = BytesBuilder();
  int _lastChunk = -1;

  /// The score from the last completed record.
  double? focus;

  static bool isChunk(List<int> b) =>
      b.length > 8 && b[0] == 0x09 && b[1] == 0x9A && b[2] == 0x03 && b[3] == 0x84 && b[4] == 0xAA && b[5] == 0xFC;

  FocusResult add(Uint8List b) {
    final index = b[7] | b[8] << 8;
    final length = b[6] < b.length - 9 ? b[6] : b.length - 9;
    final payload = Uint8List.sublistView(b, 9, 9 + length);
    if (index == 0) {
      reset();
      _record.add(payload);
    } else if (index == _lastChunk + 1) {
      _record.add(payload);
    } else {
      reset();
      return FocusResult.outOfOrder;
    }
    _lastChunk = index;
    if (_record.length < recordSize) return FocusResult.pending;

    final record = _record.takeBytes();
    reset();
    final value = ByteData.sublistView(record).getFloat32(focusOffset, Endian.little);
    if (!value.isFinite) return FocusResult.invalid;
    focus = value;
    return FocusResult.ready;
  }

  void reset() {
    _record.clear();
    _lastChunk = -1;
  }
}
