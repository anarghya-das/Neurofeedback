import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gaia.dart';
import 'lsl_eeg_outlet.dart';
import 'protocol.dart';
import 'signal_quality.dart';
import 'stream_processor.dart';
import 'transport.dart';

enum HeadsetState { idle, starting, streaming, stopping, error }

/// One line of command traffic, for the test app's log.
class HeadsetLogEntry {
  HeadsetLogEntry(this.message) : time = DateTime.now();

  final DateTime time;
  final String message;
}

/// Connects to an MW75 Neuro, starts and stops raw EEG, publishes it to LSL in
/// Research Kit's format and rates electrode contact once per second.
///
/// The start/stop sequence follows Neurable Research Kit 1.1.3 (see
/// docs/neurable-mw75-protocol.md). Raw-EEG licensing lives on the headset; this
/// driver only reads it and asks the user to activate the headset in Research
/// Kit if it is off.
class Mw75Headset extends ChangeNotifier {
  Mw75Headset({Mw75Transport? transport, this.streamName = defaultStreamName})
    : _transport = transport ?? Mw75Transport();

  /// The LSL name this lab's Research Kit was configured to use.
  static const defaultStreamName = 'MW75 Neuro Neurable Stream';
  static const _commandTimeout = Duration(milliseconds: 1500);

  final Mw75Transport _transport;

  /// LSL stream name; takes effect on the next start.
  String streamName;
  bool publishToLsl = true;

  /// How many bad channels per ear cup the contact summary tolerates.
  QualityStrictness get qualityStrictness => _qualityStrictness;
  QualityStrictness _qualityStrictness = QualityStrictness.standard;
  set qualityStrictness(QualityStrictness value) {
    _qualityStrictness = value;
    notifyListeners();
  }

  // State shown in the UI.
  HeadsetState _state = HeadsetState.idle;
  HeadsetState get state => _state;
  String statusText = 'Choose your headset and start streaming.';
  String? warning;
  List<PairedDevice> devices = const [];
  PairedDevice? selectedDevice;
  int? batteryPercent;
  String? firmwareVersion;
  Mw75SignalQuality? quality;

  /// The headset's own 0–5 contact level per ear cup, which it reports
  /// unprompted (seen at connect and when contact changes). Separate from
  /// [quality], which this driver computes per electrode from the raw EEG.
  int? leftCupContact;
  int? rightCupContact;
  DateTime? cupContactUpdatedAt;

  // Live statistics.
  int get packetsReceived => _processor.received;
  int get packetsLost => _processor.lost;
  double get lossRatio => _processor.lossRatio;

  /// Packet loss over the last 10 seconds; null until there is data.
  double? get recentLossRatio => _recentLoss.ratio;

  /// Times data stopped for more than 0.5 s, so the amount lost is uncertain.
  int get longDropouts => _processor.longDropouts;
  int get checksumErrors => _parser.checksumErrors;
  double packetRate = 0;

  /// Samples per second the headset actually delivers (≈496.5 on the lab's
  /// MW75), measured from packet arrivals; null for the first 10 seconds.
  double? get effectiveRate => _processor.effectiveRate;
  bool get lslHasConsumers => _outlet?.hasConsumers ?? false;

  bool get interpolate => _processor.interpolate;
  set interpolate(bool value) {
    _processor.interpolate = value;
    notifyListeners();
  }

  bool get removeDcOffset => _processor.removeDcOffset;
  set removeDcOffset(bool value) {
    _processor.removeDcOffset = value;
    notifyListeners();
  }

  /// Command traffic and lifecycle events, newest last.
  final log = ListQueue<HeadsetLogEntry>();

  /// Every sample pushed to LSL, for live plots.
  Stream<List<Mw75Sample>> get samples => _samples.stream;
  final _samples = StreamController<List<Mw75Sample>>.broadcast();

  final _parser = Mw75PacketParser();
  final _gaia = GaiaFrameParser();
  final _quality = Mw75SignalQualityEstimator();
  final _processor = Mw75StreamProcessor();
  final _recentLoss = LossWindow();
  final _waiters = <_ReplyWaiter>[];
  LslEegOutlet? _outlet;
  StreamSubscription<RfcommChunk>? _chunkSub;
  StreamSubscription<RfcommRole>? _closedSub;
  Timer? _statsTimer;
  int _packetsAtLastTick = 0;

  /// Added to native arrival times to put them in LSL time. Zero when the native
  /// clock already is LSL's clock, which is the expected case.
  double _clockOffset = 0;

  Future<void> refreshDevices() async {
    try {
      // macOS can list the same device more than once (seen after a restart),
      // so keep one entry per address, preferring the connected one.
      final byAddress = <String, PairedDevice>{};
      for (final d in await _transport.pairedDevices()) {
        final key = normalizeAddress(d.address);
        final kept = byAddress[key];
        if (kept == null || (d.connected && !kept.connected)) byAddress[key] = d;
      }
      final paired = byAddress.values.toList();
      paired.sort((a, b) {
        final am = _looksLikeMw75(a) ? 0 : 1;
        final bm = _looksLikeMw75(b) ? 0 : 1;
        return am != bm ? am - bm : a.name.compareTo(b.name);
      });
      devices = paired;
      final keep = selectedDevice == null
          ? null
          : paired.where((d) => d.address == selectedDevice!.address).firstOrNull;
      selectedDevice = keep ?? paired.where(_looksLikeMw75).firstOrNull;
      if (paired.isEmpty) {
        statusText = 'No paired Bluetooth devices. Pair the headset in System Settings › Bluetooth.';
      } else if (selectedDevice == null) {
        statusText = 'No MW75 among paired devices. Pick it from the list if it has another name.';
      }
    } catch (e) {
      statusText = 'Could not list Bluetooth devices: $e';
    }
    notifyListeners();
  }

  void selectDevice(PairedDevice device) {
    selectedDevice = device;
    notifyListeners();
  }

  /// Opens the channels and runs Research Kit's raw-mode start sequence.
  Future<void> start() async {
    final device = selectedDevice;
    if (device == null || _state == HeadsetState.starting || _state == HeadsetState.streaming) return;
    _setState(HeadsetState.starting, 'Opening Bluetooth channels…');
    warning = null;
    quality = null;
    leftCupContact = null;
    rightCupContact = null;
    cupContactUpdatedAt = null;
    batteryPercent = null;
    _resetStreamState();

    _chunkSub = _transport.chunks.listen(_onChunk);
    _closedSub = _transport.closed.listen(_onChannelClosed);

    try {
      final channels = await _transport.open(
        address: device.address,
        dataChannel: Mw75Protocol.dataRfcommChannel,
        commandServiceUuid16: Mw75Protocol.commandServiceUuid16,
      );
      _log('Opened command channel ${channels.commandChannel} and data channel ${channels.dataChannel}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _calibrateClock();

      // A previous session that ended without disable_raw_mode (a crash, a force
      // quit) leaves the headset streaming. Research Kit then skips the start
      // commands; replies are also unreliable on a link that busy.
      final alreadyStreaming = await _waitForPackets(const Duration(milliseconds: 1500));

      _setStatus('Checking the headset…');
      final count = await _send(GaiaCommand.getConnectedDeviceCount);
      if (count != null && count.bytes.length > 10 && count.bytes[10] >= 2) {
        warning =
            'The headset is also connected to another device. If no data arrives, disconnect it there and try again.';
      }

      final battery = await _send(GaiaCommand.getBatteryLevel);
      batteryPercent = battery?.value;
      if (batteryPercent != null && batteryPercent! < 20) {
        warning = 'Battery is at $batteryPercent%. Charge the headset before a long session.';
      }

      final version = await _send(GaiaCommand.getFirmwareVersion);
      if (version != null) {
        firmwareVersion = String.fromCharCodes(version.payload.where((b) => b >= 0x20 && b < 0x7F));
      }

      if (alreadyStreaming) {
        _log('Headset is already streaming raw EEG; skipping start commands');
      } else {
        final feature = await _send(GaiaCommand.getRawEegFeatureStatus);
        if (feature != null && feature.value == 0) {
          throw const _StartFailure(
            'Raw EEG is not activated on this headset. Activate it once in Neurable Research Kit, then try again.',
          );
        }

        // Only an explicit "off" means off; a lost reply is not a reason to resend.
        final mode = await _send(GaiaCommand.getEegMode);
        if (mode != null && mode.value == 0) {
          _log('EEG is off; enabling it');
          await _send(GaiaCommand.enableEeg);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }

        await _syncClock();
      }

      if (publishToLsl) _openOutlet(device);

      if (!alreadyStreaming) {
        _setStatus('Starting raw EEG…');
        final ack = await _send(GaiaCommand.enableRawMode);
        if (ack == null || !ack.acknowledged) {
          // Replies are sometimes lost on a busy link; arriving EEG is the real
          // confirmation.
          if (!await _waitForPackets(const Duration(seconds: 4))) {
            await _send(GaiaCommand.disableRawMode);
            throw const _StartFailure(
              'The headset did not start sending EEG. Turn it off and on, then try again.',
            );
          }
          _log('enable_raw_mode reply was lost, but EEG is arriving');
        }
      }

      _statsTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
      _setState(
        HeadsetState.streaming,
        publishToLsl ? 'Streaming to LSL as "$streamName".' : 'Streaming (LSL output off).',
      );
    } catch (e) {
      final message = e is _StartFailure ? e.message : _describe(e);
      _log('Start failed: $message');
      await _teardown(sendDisable: false);
      _setState(HeadsetState.error, message);
    }
  }

  /// Research Kit's disconnect: leave raw mode, then close both channels.
  Future<void> stop() async {
    if (_state != HeadsetState.streaming && _state != HeadsetState.error) return;
    _setState(HeadsetState.stopping, 'Stopping…');
    await _teardown(sendDisable: true);
    _setState(HeadsetState.idle, 'Stopped. ${_summary()}');
  }

  @override
  void dispose() {
    unawaited(_teardown(sendDisable: _state == HeadsetState.streaming));
    _samples.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  Future<void> _syncClock() async {
    final reply = await _send(GaiaCommand.getClock);
    final now = DateTime.now();
    if (reply != null && reply.bytes.length >= 15 && reply.acknowledged) {
      final data = reply.bytes;
      final seconds = data[9] | data[10] << 8 | data[11] << 16 | data[12] << 24;
      final offset = (data[13] | data[14] << 8).toSigned(16);
      final drift = (seconds - now.millisecondsSinceEpoch ~/ 1000).abs();
      if (drift <= 2 && offset == now.timeZoneOffset.inMinutes) return;
      _log('Headset clock off by ${drift}s (offset $offset min); updating');
    }
    await _send(GaiaCommand.updateClock(now));
  }

  /// True once any EEG packet has been decoded since this start, waiting up to
  /// [timeout].
  Future<bool> _waitForPackets(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_processor.received == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _processor.received > 0;
  }

  /// Confirms the native timestamps share LSL's clock. If they ever don't (for
  /// example a liblsl build reading a different clock), measures the offset with
  /// the tightest of a few round trips and corrects for it.
  Future<void> _calibrateClock() async {
    var best = double.infinity;
    var offset = 0.0;
    for (var i = 0; i < 5; i++) {
      final before = LslEegOutlet.localClock();
      final host = await _transport.hostClock();
      final after = LslEegOutlet.localClock();
      if (after - before < best) {
        best = after - before;
        offset = (before + after) / 2 - host;
      }
    }
    _clockOffset = offset.abs() < 0.01 ? 0 : offset;
    if (_clockOffset != 0) {
      _log('Native clock differs from LSL by ${offset.toStringAsFixed(3)} s; correcting timestamps');
    }
  }

  void _openOutlet(PairedDevice device) {
    _outlet = LslEegOutlet.create(
      name: streamName,
      type: 'EEG',
      // Research Kit uses the device id, i.e. the Bluetooth address, so
      // LabRecorder treats this as the same source.
      sourceId: normalizeAddress(device.address),
      nominalRate: Mw75Protocol.samplingRate,
      extraDesc: const {
        'manufacturer': 'NeurableStream',
        'sampleStatusCodes': '0 = measured; 1 = lost over Bluetooth and interpolated; '
            '2 = measured after more than 0.5 s without data (samples lost before it may be undercounted)',
      },
      channels: [
        for (var i = 1; i <= Mw75Protocol.eegChannelCount; i++)
          LslChannel('eeg$i', unit: 'microvolts', type: 'EEG'),
        const LslChannel('ref', unit: 'bit', type: 'AUX'),
        const LslChannel('drl', unit: 'bit', type: 'AUX'),
        const LslChannel('lslCumulativeCounter', unit: 'unitless', type: 'AUX'),
        // Research Kit's csvCumulativeCounter is always 0 outside its own CSV
        // recording; this slot instead says whether each sample was measured.
        const LslChannel('sampleStatus', unit: 'code', type: 'AUX'),
      ],
    );
    _log('LSL outlet "$streamName" created');
  }

  Future<GaiaFrame?> _send(GaiaCommand command) async {
    final waiter = _ReplyWaiter(command);
    _waiters.add(waiter);
    _log('→ ${command.name}  ${_hex(command.bytes)}');
    try {
      await _transport.write(RfcommRole.command, command.bytes);
      final reply = await waiter.completer.future.timeout(_commandTimeout);
      return reply;
    } on TimeoutException {
      _log('  ${command.name}: no reply');
      return null;
    } finally {
      _waiters.remove(waiter);
    }
  }

  void _onChunk(RfcommChunk chunk) {
    if (chunk.role == RfcommRole.command) {
      for (final frame in _gaia.add(chunk.bytes)) {
        final contact = frame.cupContact;
        if (contact != null) {
          final (left, right) = contact;
          leftCupContact = left;
          rightCupContact = right;
          cupContactUpdatedAt = DateTime.now();
          notifyListeners();
        }
        final waiter = _waiters.where((w) => !w.completer.isCompleted && frame.answers(w.command)).firstOrNull;
        _log('← ${frame.hex}${waiter != null ? '  (${waiter.command.name})' : ''}');
        waiter?.completer.complete(frame);
      }
      return;
    }

    final offsets = chunk.segmentOffsets;
    for (var s = 0; s < offsets.length; s++) {
      final end = s + 1 < offsets.length ? offsets[s + 1] : chunk.bytes.length;
      final segment = Uint8List.sublistView(chunk.bytes, offsets[s], end);
      for (final packet in _parser.add(segment, chunk.segmentTimes[s] + _clockOffset)) {
        _onPacket(packet);
      }
    }
  }

  void _onPacket(Mw75Packet packet) {
    final report = _quality.add(packet, packet.hostTime);
    if (report != null) quality = report;
    final out = _processor.add(packet);
    if (out.isEmpty) return;
    _outlet?.pushChunk([for (final s in out) s.values], [for (final s in out) s.time]);
    if (_samples.hasListener) _samples.add(out);
  }

  void _onChannelClosed(RfcommRole role) {
    _log('${role.name} channel closed by the headset');
    if (_state == HeadsetState.streaming || _state == HeadsetState.starting) {
      unawaited(_teardown(sendDisable: false));
      _setState(HeadsetState.error, 'The headset disconnected. Check that it is on and in range, then start again.');
    }
  }

  void _tick() {
    final received = _processor.received;
    packetRate = (received - _packetsAtLastTick) * 4.0;
    _packetsAtLastTick = received;
    _recentLoss.add(received, _processor.lost);
    if (_state == HeadsetState.streaming && received == 0 && warning == null) {
      warning = 'No EEG data yet. Make sure Research Kit is closed and the headset is awake.';
    }
    notifyListeners();
  }

  Future<void> _teardown({required bool sendDisable}) async {
    _statsTimer?.cancel();
    _statsTimer = null;
    if (sendDisable) {
      await _send(GaiaCommand.disableRawMode);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    try {
      await _transport.close();
    } catch (_) {}
    await _chunkSub?.cancel();
    await _closedSub?.cancel();
    _chunkSub = null;
    _closedSub = null;
    for (final w in _waiters) {
      if (!w.completer.isCompleted) w.completer.completeError(TimeoutException('closed'));
    }
    _waiters.clear();
    _outlet?.close();
    _outlet = null;
    packetRate = 0;
  }

  void _resetStreamState() {
    _parser.reset();
    _parser.checksumErrors = 0;
    _parser.droppedBytes = 0;
    _gaia.reset();
    _quality.clear();
    _processor.reset();
    _recentLoss.clear();
    _packetsAtLastTick = 0;
  }

  String _summary() {
    final total = packetsReceived + packetsLost;
    if (total == 0) return 'No EEG packets were received.';
    return 'Received $packetsReceived packets, ${(lossRatio * 100).toStringAsFixed(1)}% lost in transit.';
  }

  void _setState(HeadsetState state, String status) {
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
    if (kDebugMode) debugPrint('[mw75] $message');
  }

  static String _describe(Object e) => e is PlatformException ? e.message ?? e.code : e.toString();

  static bool _looksLikeMw75(PairedDevice d) => d.name.toUpperCase().contains('MW75');

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

/// `50-0b-91-a9-39-84` → `50:0B:91:A9:39:84`, the form Research Kit uses as the
/// device id.
String normalizeAddress(String address) => address.replaceAll('-', ':').toUpperCase();

class _ReplyWaiter {
  _ReplyWaiter(this.command);

  final GaiaCommand command;
  final completer = Completer<GaiaFrame>();
}

class _StartFailure implements Exception {
  const _StartFailure(this.message);

  final String message;
}
