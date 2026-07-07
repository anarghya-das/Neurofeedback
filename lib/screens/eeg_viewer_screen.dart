import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:spectrum_lib/spectrum_lib.dart';

import '../models/stream_info.dart';
import '../models/eeg_data_manager.dart';
import '../models/stimulus_marker.dart';
import '../services/lsl_service.dart';
import '../services/lsl_marker_service.dart';
import '../widgets/band_power_bar_chart.dart';
import '../widgets/stacked_eeg_chart.dart';
import 'dart:convert';
import 'package:desktop_multi_window/desktop_multi_window.dart';

class EEGViewer extends StatefulWidget {
  const EEGViewer({super.key, required this.title});

  final String title;

  @override
  State<EEGViewer> createState() => _EEGViewerState();
}

class _EEGViewerState extends State<EEGViewer> {
  final LSLService _lslService = LSLService();
  final LSLMarkerService _markerService = LSLMarkerService();
  final EEGDataManager _dataManager = EEGDataManager();
  final AudioPlayer _audioPlayer = AudioPlayer();

  List<StreamInfo> _availableStreams = [];
  String _statusText = 'Ready to search for streams';
  String _latestSample = 'No samples yet';
  int? _selectedStreamIndex;
  int? _userWindowId;
  StreamSubscription? _sampleSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;

  double _timeWindowSeconds = 4.0;
  double _amplitudeScale = 200.0;

  double _deltaRaw = 0.0;
  double _thetaRaw = 0.0;
  double _alphaRaw = 0.0;
  double _betaRaw = 0.0;
  double _gammaRaw = 0.0;

  SpectrumLib? _spectrumLib;

  static const double _smooth = 0.6;
  static const int _targetUpdatesPerSecond = 10;
  int _bandUpdateCounter = 0;
  int _fftWindowLength = 256;

  bool _stimulusActive = false;
  String? _activeStimulusLabel;
  DateTime? _stimulusStartTime;

  double? _baselineDelta;
  double? _baselineTheta;
  double? _baselineAlpha;
  double? _baselineBeta;
  double? _baselineGamma;

  final List<String> _audioFiles = [];
  final Map<String, Duration?> _audioDurations = {};
  int _currentAudioIndex = -1;
  bool _loopPlaylist = true;
  bool _audioPaused = false;
  Duration _audioPosition = Duration.zero;
  Duration? _currentAudioDuration;

  final List<StimulusMarker> _markers = [];
  bool _labRecorderRecording = false;
  bool _labRecorderBusy = false;

  Future<File> _saveMarkersCsv() async {
    final dir = await getApplicationDocumentsDirectory();

    final sessionTime = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');

    final file = File('${dir.path}/audio_markers_$sessionTime.csv');

    final buffer = StringBuffer();

    buffer.writeln('graph_time_seconds,real_time,type,label,marker_value');

    for (final marker in _markers) {
      final markerValue = marker.label.isEmpty
          ? marker.type
          : '${marker.type}:${marker.label}';

      buffer.writeln(
        [
          marker.graphTimeSeconds.toStringAsFixed(6),
          marker.wallTime.toIso8601String(),
          _csv(marker.type),
          _csv(marker.label),
          _csv(markerValue),
        ].join(','),
      );
    }

    await file.writeAsString(buffer.toString());
    developer.log('Saved markers CSV: ${file.path}');
    return file;
  }

  String _csv(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  @override
  void initState() {
    super.initState();
    _audioPlayer.setVolume(0.8);
    _setupUserWindowMessageHandler();
    _initializeLSL();
    _initializeMarkers();
    _initializeAudio();
  }

  @override
  void dispose() {
    _sampleSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _audioPlayer.dispose();
    _spectrumLib?.dispose();
    _lslService.dispose();
    _markerService.dispose();
    super.dispose();
  }

  Future<void> _openLabRecorder() async {
    try {
      var result = await Process.run('open', ['-a', 'LabRecorder']);

      if (result.exitCode != 0) {
        result = await Process.run('open', ['/Applications/LabRecorder.app']);
      }

      if (result.exitCode != 0) {
        throw Exception(result.stderr.toString());
      }

      print('LabRecorder opened');

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('LabRecorder opened')));
    } catch (e) {
      print('Failed to open LabRecorder: $e');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to open LabRecorder. Make sure it is in Applications. Error: $e',
          ),
        ),
      );
    }
  }

  Future<void> _sendLabRecorderCommand(String command) async {
    final socket = await Socket.connect(
      '127.0.0.1',
      22345,
      timeout: const Duration(seconds: 2),
    );

    socket.write('$command\n');
    await socket.flush();
    await socket.close();

    print('Sent LabRecorder command: $command');
  }

  Future<void> _startLabRecorderRecording() async {
    if (_labRecorderRecording || _labRecorderBusy) return;

    setState(() {
      _labRecorderBusy = true;
    });

    try {
      var result = await Process.run('open', ['-a', 'LabRecorder']);

      if (result.exitCode != 0) {
        result = await Process.run('open', ['/Applications/LabRecorder.app']);
      }

      if (result.exitCode != 0) {
        throw Exception('Could not open LabRecorder: ${result.stderr}');
      }

      await Future.delayed(const Duration(seconds: 2));

      await _sendLabRecorderCommand('update');
      await Future.delayed(const Duration(seconds: 1));

      await _sendLabRecorderCommand('select all');
      await Future.delayed(const Duration(milliseconds: 300));

      await _sendLabRecorderCommand('start');

      if (!mounted) return;

      setState(() {
        _labRecorderRecording = true;
        _statusText = 'LabRecorder recording LSL streams';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('LabRecorder recording started')),
      );
    } catch (e) {
      print('Failed to start LabRecorder recording: $e');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not start LabRecorder. Open LabRecorder and check EnableRCS. Error: $e',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _labRecorderBusy = false;
        });
      }
    }
  }

  Future<void> _stopLabRecorderRecording() async {
    if (!_labRecorderRecording || _labRecorderBusy) return;

    setState(() {
      _labRecorderBusy = true;
    });

    try {
      await _sendLabRecorderCommand('stop');

      if (!mounted) return;

      setState(() {
        _labRecorderRecording = false;
        _statusText = 'LabRecorder recording stopped';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('LabRecorder recording stopped')),
      );
    } catch (e) {
      print('Failed to stop LabRecorder recording: $e');

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to stop LabRecorder: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _labRecorderBusy = false;
        });
      }
    }
  }

  Future<void> _initializeMarkers() async {
    try {
      await _markerService.initialize();

      developer.log('AudioMarkers LSL stream initialized');

      if (!mounted) return;

      setState(() {
        _statusText = 'AudioMarkers LSL stream initialized';
      });
    } catch (e, st) {
      developer.log(
        'AudioMarkers stream failed to initialize',
        error: e,
        stackTrace: st,
      );

      if (!mounted) return;

      setState(() {
        _statusText = 'AudioMarkers failed: $e';
      });
    }
  }

  void _initializeAudio() {
    _playerStateSubscription = _audioPlayer.playerStateStream.listen((
      state,
    ) async {
      if (state.processingState == ProcessingState.completed) {
        await _handleAudioCompleted();
      }
    });

    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      if (!mounted) return;
      setState(() {
        _audioPosition = position;
      });
    });

    _durationSubscription = _audioPlayer.durationStream.listen((duration) {
      if (!mounted) return;
      setState(() {
        _currentAudioDuration = duration;
        final currentPath = _currentAudioPath;
        if (currentPath != null) {
          _audioDurations[currentPath] = duration;
        }
      });
    });
  }

  Future<void> _initializeLSL() async {
    try {
      await _lslService.initialize();
      if (!mounted) return;
      setState(() {
        _statusText = 'LSL service initialized';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Error initializing LSL: $e';
      });
    }
  }

  Future<void> _searchForStreams() async {
    try {
      setState(() {
        _statusText = 'Searching for streams...';
      });

      final streams = await _lslService.searchStreams();

      if (!mounted) return;
      setState(() {
        _availableStreams = streams;
        _selectedStreamIndex = null;
        _statusText = 'Found ${_availableStreams.length} stream(s)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Error searching for streams: $e';
      });
    }
  }

  int _chooseOpenBciLikeWindow(int samplingRate) {
    if (samplingRate == 125 || samplingRate == 200 || samplingRate == 250) {
      return 256;
    }
    if (samplingRate == 1000) return 1024;
    if (samplingRate == 1600) return 2048;
    if (samplingRate >= 256) return 256;
    if (samplingRate >= 128) return 128;
    return 64;
  }

  void _initSpectrumLib(int samplingRate) {
    if (samplingRate <= 0) return;

    try {
      _spectrumLib?.dispose();

      _fftWindowLength = _chooseOpenBciLikeWindow(samplingRate);

      _spectrumLib = SpectrumLib(
        samplingRate,
        _fftWindowLength,
        _targetUpdatesPerSecond,
      );

      // true = spectrum_lib applies its own bandwidth normalization.
      // This is the closest to PSD-density style output.
      _spectrumLib!.initParams(samplingRate ~/ 2, true);

      // Original/OpenBCI-like window choice.
      _spectrumLib!.setHammingWinSpectrum();

      _bandUpdateCounter = 0;
      _deltaRaw = 0.0;
      _thetaRaw = 0.0;
      _alphaRaw = 0.0;
      _betaRaw = 0.0;
      _gammaRaw = 0.0;

      developer.log(
        'SpectrumLib original PSD-density initialized: '
        'samplingRate=$samplingRate, '
        'fftWindow=$_fftWindowLength, '
        'updatesPerSecond=$_targetUpdatesPerSecond',
      );
    } catch (e, st) {
      developer.log('Error initializing SpectrumLib', error: e, stackTrace: st);
    }
  }

  List<double> _preprocessForBandPower(List<double> samples) {
    if (samples.isEmpty) return const [];
    final mean = samples.reduce((a, b) => a + b) / samples.length;
    return samples.map((x) => x - mean).toList();
  }

  void _updateBandPowerFromLiveData() {
    try {
      if (_spectrumLib == null) return;
      if (!_dataManager.hasData) return;

      final samplingRate = _dataManager.samplingRate.toInt();
      if (samplingRate <= 0) return;

      final channels = _dataManager.allChannelData;
      if (channels.isEmpty) return;

      final updateEverySamples = math.max(
        1,
        (samplingRate / _targetUpdatesPerSecond).round(),
      );

      _bandUpdateCounter++;
      if (_bandUpdateCounter < updateEverySamples) return;
      _bandUpdateCounter = 0;

      final validChannels = channels
          .where((ch) => ch.length >= _fftWindowLength)
          .toList();

      if (validChannels.isEmpty) return;

      double deltaSum = 0.0;
      double thetaSum = 0.0;
      double alphaSum = 0.0;
      double betaSum = 0.0;
      double gammaSum = 0.0;

      int usedChannels = 0;

      for (final chData in validChannels) {
        final chList = chData.toList();
        final start = chList.length - _fftWindowLength;

        final recentSamples = <double>[];

        for (int i = start; i < chList.length; i++) {
          recentSamples.add(chList[i].y.toDouble());
        }

        final processedSamples = _preprocessForBandPower(recentSamples);

        if (processedSamples.isEmpty) continue;

        _spectrumLib!.computeSpectrum(processedSamples);

        final waves = _spectrumLib!.readWavesSpectrumInfo();

        // spectrum_lib raw wave values are treated as amplitude spectral density.
        // Squaring gives power spectral density: µV²/Hz.
        final deltaPower = math.max(
          1e-6,
          math.pow(waves.deltaRaw.toDouble(), 2).toDouble(),
        );

        final thetaPower = math.max(
          1e-6,
          math.pow(waves.thetaRaw.toDouble(), 2).toDouble(),
        );

        final alphaPower = math.max(
          1e-6,
          math.pow(waves.alphaRaw.toDouble(), 2).toDouble(),
        );

        final betaPower = math.max(
          1e-6,
          math.pow(waves.betaRaw.toDouble(), 2).toDouble(),
        );

        final gammaPower = math.max(
          1e-6,
          math.pow(waves.gammaRaw.toDouble(), 2).toDouble(),
        );

        deltaSum += deltaPower;
        thetaSum += thetaPower;
        alphaSum += alphaPower;
        betaSum += betaPower;
        gammaSum += gammaPower;

        usedChannels++;
      }

      if (usedChannels == 0) return;

      final newDelta = deltaSum / usedChannels;
      final newTheta = thetaSum / usedChannels;
      final newAlpha = alphaSum / usedChannels;
      final newBeta = betaSum / usedChannels;
      final newGamma = gammaSum / usedChannels;

      print(
        'SpectrumLib original PSD-density | '
        'usedChannels=$usedChannels | '
        'Delta=${newDelta.toStringAsFixed(3)} | '
        'Theta=${newTheta.toStringAsFixed(3)} | '
        'Alpha=${newAlpha.toStringAsFixed(3)} | '
        'Beta=${newBeta.toStringAsFixed(3)} | '
        'Gamma=${newGamma.toStringAsFixed(3)}',
      );

      if (!mounted) return;

      setState(() {
        _deltaRaw = _deltaRaw == 0.0
            ? newDelta
            : _smooth * _deltaRaw + (1 - _smooth) * newDelta;

        _thetaRaw = _thetaRaw == 0.0
            ? newTheta
            : _smooth * _thetaRaw + (1 - _smooth) * newTheta;

        _alphaRaw = _alphaRaw == 0.0
            ? newAlpha
            : _smooth * _alphaRaw + (1 - _smooth) * newAlpha;

        _betaRaw = _betaRaw == 0.0
            ? newBeta
            : _smooth * _betaRaw + (1 - _smooth) * newBeta;

        _gammaRaw = _gammaRaw == 0.0
            ? newGamma
            : _smooth * _gammaRaw + (1 - _smooth) * newGamma;
      });

      _sendBandPowerToUserWindow();
    } catch (e, st) {
      print('Band power update failed: $e');
      developer.log('Band power update failed', error: e, stackTrace: st);
    }
  }

  double _currentGraphTime() => _dataManager.currentTimeSeconds;

  Future<void> _recordAndEmitMarker(String type, String label) async {
    final markerValue = label.isEmpty ? type : '$type:$label';

    final marker = StimulusMarker(
      graphTimeSeconds: _currentGraphTime(),
      type: type,
      label: label,
      wallTime: DateTime.now(),
    );

    if (mounted) {
      setState(() {
        _markers.add(marker);
      });
    }

    try {
      await _markerService.sendMarker(markerValue);

      developer.log('Successfully emitted LSL marker: $markerValue');
    } catch (e, st) {
      developer.log(
        'FAILED TO EMIT LSL MARKER: $markerValue',
        error: e,
        stackTrace: st,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to emit LSL marker: $e')),
        );
      }
    }
  }

  Future<void> onAudioStartMarker(String label) async {
    if (!mounted) return;

    setState(() {
      _stimulusActive = true;
      _activeStimulusLabel = label;
      _stimulusStartTime = DateTime.now();
      _baselineDelta = _deltaRaw;
      _baselineTheta = _thetaRaw;
      _baselineAlpha = _alphaRaw;
      _baselineBeta = _betaRaw;
      _baselineGamma = _gammaRaw;
      _audioPaused = false;
    });

    await _recordAndEmitMarker('AUDIO_START', label);
  }

  Future<void> onAudioStopMarker(String label) async {
    if (!mounted) return;

    setState(() {
      _stimulusActive = false;
      _activeStimulusLabel = label;
    });

    await _recordAndEmitMarker('AUDIO_STOP', label);
  }

  Future<void> onAudioPauseMarker() async {
    if (!mounted) return;
    setState(() {
      _audioPaused = true;
      _stimulusActive = false;
    });

    await _recordAndEmitMarker('AUDIO_PAUSE', '');
  }

  Future<void> _pickAudioFiles() async {
    print('ADD AUDIO FILES BUTTON PRESSED');

    if (!mounted) return;

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowMultiple: true,
        allowedExtensions: ['wav', 'mp3', 'flac', 'm4a', 'aac', 'ogg'],
        withData: false,
      );

      print('Picker result: $result');

      if (result == null) {
        print('User cancelled picker');
        return;
      }

      if (result.files.isEmpty) {
        print('No files returned');
        return;
      }

      final newPaths = <String>[];
      for (final file in result.files) {
        print('Picked file: name=${file.name}, path=${file.path}');
        if (file.path != null && file.path!.isNotEmpty) {
          newPaths.add(file.path!);
          _audioDurations[file.path!] = null;
        }
      }

      print('Resolved paths: $newPaths');

      if (newPaths.isEmpty) {
        print('No usable file paths found');
        return;
      }

      setState(() {
        _audioFiles.addAll(newPaths);
        if (_currentAudioIndex == -1 && _audioFiles.isNotEmpty) {
          _currentAudioIndex = 0;
        }
      });
    } catch (e) {
      print('File picker failed: $e');
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('File picker error'),
          content: Text('$e'),
        ),
      );
    }
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? path : parts.last;
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmtNullableDuration(Duration? d) {
    if (d == null) return '--:--';
    return _fmtDuration(d);
  }

  String? get _currentAudioPath =>
      (_currentAudioIndex >= 0 && _currentAudioIndex < _audioFiles.length)
      ? _audioFiles[_currentAudioIndex]
      : null;

  String? get _nextAudioName {
    if (_audioFiles.isEmpty || _currentAudioIndex < 0) return null;
    if (_audioFiles.length == 1) return _fileName(_audioFiles.first);

    final next = _currentAudioIndex + 1;
    if (next < _audioFiles.length) {
      return _fileName(_audioFiles[next]);
    }
    if (_loopPlaylist) {
      return _fileName(_audioFiles.first);
    }
    return null;
  }

  Future<void> _loadCurrentAudio() async {
    if (_currentAudioIndex < 0 || _currentAudioIndex >= _audioFiles.length) {
      return;
    }

    final path = _audioFiles[_currentAudioIndex];
    await _audioPlayer.setFilePath(path);

    if (mounted) {
      setState(() {
        _currentAudioDuration = _audioPlayer.duration;
        _audioDurations[path] = _audioPlayer.duration;
      });
    }
  }

  Future<void> _playCurrentAudio() async {
    if (_audioFiles.isEmpty) return;

    if (_currentAudioIndex == -1) {
      setState(() => _currentAudioIndex = 0);
    }

    // Start LabRecorder first.
    await _startLabRecorderRecording();

    // Give LabRecorder time to actually begin writing samples.
    await Future.delayed(const Duration(milliseconds: 1000));

    await _loadCurrentAudio();

    final label = _fileName(_audioFiles[_currentAudioIndex]);

    // Send the start marker while LabRecorder is definitely recording.
    await onAudioStartMarker(label);

    // Small delay so the marker enters the stream before audio begins.
    await Future.delayed(const Duration(milliseconds: 200));

    await _audioPlayer.play();
  }

  Future<void> _resumeAudio() async {
    if (_currentAudioIndex < 0 || _currentAudioIndex >= _audioFiles.length) {
      return;
    }
    final label = _fileName(_audioFiles[_currentAudioIndex]);
    await onAudioStartMarker(label);
    await _audioPlayer.play();
  }

  Future<void> _pauseAudio() async {
    await _audioPlayer.pause();
    await onAudioPauseMarker();
  }

  Future<void> _stopAudio() async {
    if (_currentAudioIndex >= 0 && _currentAudioIndex < _audioFiles.length) {
      final label = _fileName(_audioFiles[_currentAudioIndex]);

      await _audioPlayer.stop();

      // Send AUDIO_STOP marker first.
      await onAudioStopMarker(label);

      // Give LabRecorder time to receive/write the marker before stopping.
      await Future.delayed(const Duration(milliseconds: 1000));
    } else {
      await _audioPlayer.stop();
    }

    await _stopLabRecorderRecording();

    if (mounted) {
      setState(() {
        _audioPosition = Duration.zero;
      });
    }
  }

  Future<void> _nextAudio() async {
    if (_audioFiles.isEmpty) return;

    if (_currentAudioIndex >= 0 && _currentAudioIndex < _audioFiles.length) {
      await _recordAndEmitMarker(
        'AUDIO_NEXT',
        _fileName(_audioFiles[_currentAudioIndex]),
      );
    }

    if (_currentAudioIndex < 0) {
      setState(() => _currentAudioIndex = 0);
    } else {
      final next = _currentAudioIndex + 1;
      if (next >= _audioFiles.length) {
        if (!_loopPlaylist) return;
        setState(() => _currentAudioIndex = 0);
      } else {
        setState(() => _currentAudioIndex = next);
      }
    }

    await _playCurrentAudio();
  }

  Future<void> _previousAudio() async {
    if (_audioFiles.isEmpty) return;

    if (_currentAudioIndex <= 0) {
      setState(
        () => _currentAudioIndex = _loopPlaylist ? _audioFiles.length - 1 : 0,
      );
    } else {
      setState(() => _currentAudioIndex = _currentAudioIndex - 1);
    }

    await _playCurrentAudio();
  }

  Future<void> _handleAudioCompleted() async {
    if (_currentAudioIndex >= 0 && _currentAudioIndex < _audioFiles.length) {
      final label = _fileName(_audioFiles[_currentAudioIndex]);
      await onAudioStopMarker(label);
      await _recordAndEmitMarker('AUDIO_NEXT', label);
    }

    final next = _currentAudioIndex + 1;
    if (next < _audioFiles.length) {
      setState(() => _currentAudioIndex = next);
      await _playCurrentAudio();
      return;
    }

    if (_loopPlaylist && _audioFiles.isNotEmpty) {
      setState(() => _currentAudioIndex = 0);
      await _playCurrentAudio();
      return;
    }

    if (mounted) {
      setState(() {
        _audioPosition = Duration.zero;
      });
    }
  }

  void _removeAudioAt(int index) {
    if (index < 0 || index >= _audioFiles.length) return;

    final removingCurrent = index == _currentAudioIndex;
    final removed = _audioFiles[index];

    setState(() {
      _audioFiles.removeAt(index);
      _audioDurations.remove(removed);

      if (_audioFiles.isEmpty) {
        _currentAudioIndex = -1;
      } else if (_currentAudioIndex > index) {
        _currentAudioIndex -= 1;
      } else if (_currentAudioIndex >= _audioFiles.length) {
        _currentAudioIndex = _audioFiles.length - 1;
      }
    });

    if (removingCurrent) {
      _audioPlayer.stop();
      onAudioStopMarker(_fileName(removed));
    }
  }

  Future<void> _connectToSelectedStream() async {
    if (_selectedStreamIndex == null ||
        _selectedStreamIndex! >= _availableStreams.length) {
      setState(() {
        _statusText = 'No valid stream selected to connect to';
      });
      return;
    }

    try {
      setState(() {
        _statusText = 'Connecting to stream...';
      });

      final selectedStream = _availableStreams[_selectedStreamIndex!];
      final connected = await _lslService.connectToStream(selectedStream);

      if (connected) {
        if (selectedStream.nominalSampleRate > 0) {
          _dataManager.updateSamplingRate(selectedStream.nominalSampleRate);
          _initSpectrumLib(selectedStream.nominalSampleRate.toInt());
        }

        if (!mounted) return;
        setState(() {
          _statusText =
              'Connected to ${selectedStream.name} (ID: ${selectedStream.id})';
        });
      } else {
        if (!mounted) return;
        setState(() {
          _statusText = 'Failed to connect to stream';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Error connecting to stream: $e';
      });
    }
  }

  Future<void> _startStreaming() async {
    try {
      if (_lslService.openInletId == null && _selectedStreamIndex != null) {
        await _connectToSelectedStream();
        if (_lslService.openInletId == null) return;
      }

      await _sampleSubscription?.cancel();

      final stream = await _lslService.startStreaming();

      _sampleSubscription = stream.listen((sample) {
        _dataManager.processSample(sample.$1, sample.$2);

        if (mounted) {
          setState(() {
            _latestSample = 'Sample: ${sample.$1}\nTimestamp: ${sample.$2}';
          });
        }

        _updateBandPowerFromLiveData();
      });

      if (!mounted) return;
      setState(() {
        _statusText = 'Streaming data...';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Error starting stream: $e';
      });
      developer.log('Error starting stream: $e');
    }
  }

  void _stopStreaming() {
    _lslService.stopStreaming();
    _sampleSubscription?.cancel();
    setState(() {
      _statusText = 'Stopped streaming';
    });
  }

  void _onStreamSelected(int index) {
    setState(() {
      _selectedStreamIndex = index;
    });
  }

  void _onTimeWindowChanged(double value) {
    setState(() {
      _timeWindowSeconds = value;
    });
  }

  void _onAmplitudeScaleChanged(double value) {
    setState(() {
      _amplitudeScale = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentPath = _currentAudioPath;
    final currentFile = currentPath != null ? _fileName(currentPath) : null;
    final currentDuration = currentPath != null
        ? _audioDurations[currentPath]
        : null;
    final selectedStream =
        _selectedStreamIndex != null &&
            _selectedStreamIndex! < _availableStreams.length
        ? _availableStreams[_selectedStreamIndex!]
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 950;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 16 : 72,
                vertical: 18,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1220),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'EEG Data Processing System',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                        color: Color(0xFF111216),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Real-time EEG analysis with LSL stream integration and audio simulation',
                      style: TextStyle(fontSize: 12, color: Color(0xFF69707D)),
                    ),
                    const SizedBox(height: 20),

                    if (isCompact) ...[
                      Column(
                        children: [
                          _leftColumn(selectedStream),
                          const SizedBox(height: 16),
                          _rightColumn(
                            currentFile: currentFile,
                            currentDuration: currentDuration,
                          ),
                        ],
                      ),
                    ] else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 380,
                            child: _leftColumn(selectedStream),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: _rightColumn(
                              currentFile: currentFile,
                              currentDuration: currentDuration,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _leftColumn(StreamInfo? selectedStream) {
    final activeChannels = _dataManager.allChannelData
        .where((q) => q.isNotEmpty)
        .length;
    final displayChannelCount = math.max(8, _dataManager.channelCount).toInt();

    return Column(
      children: [
        _DashboardCard(
          title: 'LSL Stream Connection',
          trailing: _StatusBadge(
            text: _lslService.isStreaming
                ? 'Streaming'
                : _lslService.openInletId != null
                ? 'Connected'
                : 'Disconnected',
            active: _lslService.isStreaming || _lslService.openInletId != null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Configure and connect to LSL stream for EEG data',
                style: TextStyle(fontSize: 12, color: Color(0xFF69707D)),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Stream Name',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  OutlinedButton.icon(
                    onPressed: _searchForStreams,
                    icon: const Icon(Icons.search_rounded, size: 14),
                    label: const Text(
                      'Search Streams',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      foregroundColor: const Color(0xFF111216),
                      side: const BorderSide(color: Color(0xFFE2E4EA)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _StreamPicker(
                streams: _availableStreams,
                selectedIndex: _selectedStreamIndex,
                fallbackName: selectedStream?.name ?? 'EEG_Stream',
                onSearchStreams: _searchForStreams,
                onSelected: _onStreamSelected,
              ),
              const SizedBox(height: 12),
              _DashboardButton(
                label: _lslService.isStreaming
                    ? 'Stop Stream'
                    : 'Connect to Stream',
                icon: _lslService.isStreaming
                    ? Icons.stop_rounded
                    : Icons.wifi_tethering_rounded,
                dark: true,
                onPressed: _lslService.isStreaming
                    ? _stopStreaming
                    : () async {
                        if (_availableStreams.isEmpty) {
                          await _searchForStreams();
                          return;
                        }
                        if (_selectedStreamIndex == null &&
                            _availableStreams.isNotEmpty) {
                          setState(() => _selectedStreamIndex = 0);
                        }
                        await _startStreaming();
                      },
              ),
              const SizedBox(height: 10),
              Text(
                _statusText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF69707D)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _DashboardCard(
          title: 'Channel Status',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Active Channels',
                    style: TextStyle(fontSize: 12, color: Color(0xFF374151)),
                  ),
                  _MiniDarkBadge(
                    text: '$activeChannels / $displayChannelCount',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: displayChannelCount,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisExtent: 28,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemBuilder: (context, index) {
                  final active =
                      index < _dataManager.allChannelData.length &&
                      _dataManager.allChannelData[index].isNotEmpty;
                  return _ChannelChip(label: 'Ch ${index + 1}', active: active);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _DashboardCard(
          title: 'Event Timeline',
          child: _EventTimeline(markers: _markers),
        ),
      ],
    );
  }

  Widget _rightColumn({
    required String? currentFile,
    required Duration? currentDuration,
  }) {
    return Column(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Row(
              children: [
                Expanded(
                  child: _MetricCard(
                    label: 'Avg Power',
                    value: '${_avgPower().toStringAsFixed(2)} µV²',
                    icon: Icons.show_chart_rounded,
                    tint: const Color(0xFF3B82F6),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricCard(
                    label: 'Peak Band',
                    value: _peakBand(),
                    icon: Icons.bolt_rounded,
                    tint: const Color(0xFFF59E0B),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SegmentSwitch(
          selectedIndex: _showRawWaveform ? 1 : 0,
          leftText: 'Power Spectral Density',
          rightText: 'Raw Waveform',
          onChanged: (i) => setState(() => _showRawWaveform = i == 1),
        ),
        const SizedBox(height: 16),
        _DashboardCard(
          title: _showRawWaveform
              ? 'Raw Waveform'
              : 'Power Spectral Density (PSD) - Averaged Across All Channels',
          subtitle: _showRawWaveform
              ? 'Real-time raw EEG channels with audio markers overlaid'
              : 'Real-time frequency band power visualization (FFT computed per channel, then averaged)',
          footer: !_showRawWaveform
              ? const Text(
                  'Note: Band powers are computed by performing FFT on each of the EEG channels independently, then averaging power values across all channels for each frequency band.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF596273)),
                )
              : null,
          child: SizedBox(
            height: 430,
            child: _showRawWaveform
                ? _rawWaveformPanel()
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        _showBandChart = !_showBandChart;
                      });
                    },
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _showBandChart
                          ? BandPowerBarChart(
                              key: const ValueKey('band-chart-visible'),
                              delta: _deltaRaw,
                              theta: _thetaRaw,
                              alpha: _alphaRaw,
                              beta: _betaRaw,
                              gamma: _gammaRaw,
                              baselineDelta: _baselineDelta,
                              baselineTheta: _baselineTheta,
                              baselineAlpha: _baselineAlpha,
                              baselineBeta: _baselineBeta,
                              baselineGamma: _baselineGamma,
                            )
                          : Container(
                              key: const ValueKey('band-chart-hidden'),
                              width: double.infinity,
                              height: double.infinity,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFD9DCE3),
                                ),
                              ),
                              child: const Text(
                                'Bar chart hidden — tap here to show it again',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF69707D),
                                ),
                              ),
                            ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 18),
        _DashboardCard(
          title: 'Experiment Controls',
          subtitle: 'Audio playback, markers, recording, and session controls',
          child: LayoutBuilder(
            builder: (context, constraints) {
              final twoColumn = constraints.maxWidth >= 720;

              final audioPanel = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.music_note_rounded,
                        size: 18,
                        color: Color(0xFF111216),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_audioFiles.length} audio file(s) loaded',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111216),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: _DashboardButton(
                          label: 'Add Files',
                          icon: Icons.upload_rounded,
                          onPressed: _pickAudioFiles,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DashboardButton(
                          label: 'Clear',
                          icon: Icons.delete_outline_rounded,
                          onPressed: _audioFiles.isEmpty
                              ? null
                              : _clearAudioFiles,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  if (_audioFiles.isEmpty)
                    Container(
                      height: 58,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F1F4),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'No audio files selected yet.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF69707D),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: 120,
                      child: ListView.separated(
                        itemCount: _audioFiles.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final path = _audioFiles[index];
                          final selected = index == _currentAudioIndex;

                          return _PlaylistTile(
                            index: index + 1,
                            title: _fileName(path),
                            subtitle:
                                '${_fmtNullableDuration(_audioDurations[path])}   •   ${selected ? 'Selected' : 'Ready'}',
                            selected: selected,
                            onTap: () =>
                                setState(() => _currentAudioIndex = index),
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 12),

                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9E9EF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Now Playing',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6B6D7C),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          currentFile ?? 'No track selected',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Color(0xFF111216),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 10),

                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 9,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      activeTrackColor: const Color(0xFF090716),
                      inactiveTrackColor: const Color(0xFFE9E9EF),
                      thumbColor: Colors.white,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: math.min(
                        _audioPosition.inMilliseconds.toDouble(),
                        math
                            .max(1, currentDuration?.inMilliseconds ?? 1)
                            .toDouble(),
                      ),
                      max: math
                          .max(1, currentDuration?.inMilliseconds ?? 1)
                          .toDouble(),
                      onChanged: currentDuration == null
                          ? null
                          : (v) => _audioPlayer.seek(
                              Duration(milliseconds: v.round()),
                            ),
                    ),
                  ),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _fmtDuration(_audioPosition),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B6D7C),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        _fmtNullableDuration(currentDuration) == '--:--'
                            ? '0:00'
                            : _fmtNullableDuration(currentDuration),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B6D7C),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _TransportButton(
                        icon: Icons.skip_previous_rounded,
                        onPressed: _audioFiles.isNotEmpty
                            ? _previousAudio
                            : null,
                      ),
                      const SizedBox(width: 8),
                      _TransportButton(
                        icon: _audioPlayer.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        primary: true,
                        onPressed: _audioFiles.isNotEmpty
                            ? (_audioPlayer.playing
                                  ? _pauseAudio
                                  : (_audioPaused
                                        ? _resumeAudio
                                        : _playCurrentAudio))
                            : null,
                      ),
                      const SizedBox(width: 8),
                      _TransportButton(
                        icon: Icons.stop_rounded,
                        onPressed: (_audioPlayer.playing || _audioPaused)
                            ? _stopAudio
                            : null,
                      ),
                      const SizedBox(width: 8),
                      _TransportButton(
                        icon: Icons.skip_next_rounded,
                        onPressed: _audioFiles.isNotEmpty ? _nextAudio : null,
                      ),
                      const SizedBox(width: 8),
                      _TransportButton(
                        icon: Icons.repeat_rounded,
                        selected: _loopPlaylist,
                        onPressed: () =>
                            setState(() => _loopPlaylist = !_loopPlaylist),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      const Icon(
                        Icons.volume_up_outlined,
                        color: Color(0xFF6B6D7C),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 9,
                            activeTrackColor: const Color(0xFF090716),
                            inactiveTrackColor: const Color(0xFFE5E5EA),
                            thumbColor: Colors.white,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: math.min(_audioPlayer.volume, 0.8),
                            min: 0.0,
                            max: 0.8,
                            onChanged: (v) async {
                              await _audioPlayer.setVolume(v);
                              if (mounted) setState(() {});
                              await _sendBandPowerToUserWindow();
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${(math.min(_audioPlayer.volume, 0.8) * 100).round()}%',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B6D7C),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  _DashboardButton(
                    label: 'Add Experiment Marker',
                    icon: Icons.flag_outlined,
                    onPressed: () =>
                        _recordAndEmitMarker('MANUAL_MARKER', 'Manual'),
                  ),
                ],
              );

              final sessionPanel = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE9E9ED),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Text(
                          _fmtDuration(_audioPosition),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF111216),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currentFile == null
                              ? 'Session Duration'
                              : '$currentFile • ${_fmtNullableDuration(currentDuration)}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF69707D),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  _DashboardButton(
                    label: _audioPlayer.playing
                        ? 'Pause Experiment'
                        : _audioPaused
                        ? 'Resume Experiment'
                        : 'Start Experiment',
                    icon: _audioPlayer.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    dark: true,
                    onPressed: _audioFiles.isEmpty
                        ? null
                        : (_audioPlayer.playing
                              ? _pauseAudio
                              : (_audioPaused
                                    ? _resumeAudio
                                    : _playCurrentAudio)),
                  ),

                  const SizedBox(height: 10),

                  _DashboardButton(
                    label: 'Stop Experiment',
                    icon: Icons.stop_rounded,
                    onPressed: (_audioPlayer.playing || _audioPaused)
                        ? _stopAudio
                        : null,
                  ),

                  const SizedBox(height: 10),

                  _DashboardButton(
                    label: 'Open Participant Window',
                    icon: Icons.open_in_new_rounded,
                    onPressed: _openUserWindow,
                  ),

                  const SizedBox(height: 14),

                  Row(
                    children: [
                      Expanded(
                        child: _DashboardButton(
                          label: 'Open LabRecorder',
                          icon: Icons.folder_open_rounded,
                          onPressed: _openLabRecorder,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DashboardButton(
                          label: _labRecorderRecording
                              ? 'Stop LSL Recording'
                              : 'Start LSL Recording',
                          icon: _labRecorderRecording
                              ? Icons.stop_circle_outlined
                              : Icons.fiber_manual_record_rounded,
                          dark: _labRecorderRecording,
                          onPressed: _labRecorderBusy
                              ? null
                              : (_labRecorderRecording
                                    ? _stopLabRecorderRecording
                                    : _startLabRecorderRecording),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Expanded(
                        child: _DashboardButton(
                          label: 'Save Data',
                          icon: Icons.save_alt_rounded,
                          onPressed: () async {
                            final file = await _saveMarkersCsv();

                            if (!mounted) return;

                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Saved markers to ${file.path}'),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DashboardButton(
                          label: 'Reset',
                          icon: Icons.refresh_rounded,
                          onPressed: () async {
                            await _stopAudio();
                            _dataManager.clear();
                            setState(() {
                              _latestSample = 'No samples yet';
                              _markers.clear();
                              _deltaRaw = 0;
                              _thetaRaw = 0;
                              _alphaRaw = 0;
                              _betaRaw = 0;
                              _gammaRaw = 0;
                              _baselineDelta = null;
                              _baselineTheta = null;
                              _baselineAlpha = null;
                              _baselineBeta = null;
                              _baselineGamma = null;
                              _audioPosition = Duration.zero;
                              _stimulusActive = false;
                            });
                          },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 14),

                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F1F4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Start Experiment begins audio playback and sends AUDIO_START. Stop Experiment sends AUDIO_STOP before stopping LabRecorder.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF69707D),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              );

              if (!twoColumn) {
                return Column(
                  children: [
                    audioPanel,
                    const SizedBox(height: 18),
                    const Divider(height: 1, color: Color(0xFFE2E4EA)),
                    const SizedBox(height: 18),
                    sessionPanel,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: audioPanel),
                  const SizedBox(width: 20),
                  Container(
                    width: 1,
                    height: 430,
                    color: const Color(0xFFE2E4EA),
                  ),
                  const SizedBox(width: 20),
                  Expanded(flex: 5, child: sessionPanel),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  bool _showRawWaveform = false;
  bool _showBandChart = true;

  void _clearAudioFiles() {
    _audioPlayer.stop();
    setState(() {
      _audioFiles.clear();
      _audioDurations.clear();
      _currentAudioIndex = -1;
      _audioPosition = Duration.zero;
      _currentAudioDuration = null;
      _audioPaused = false;
      _stimulusActive = false;
    });
  }

  Widget _stimuliAndMarkersPage({required bool isCompact}) {
    final currentPath = _currentAudioPath;
    final currentFile = currentPath == null ? null : _fileName(currentPath);
    final currentDuration = currentPath == null
        ? null
        : _audioDurations[currentPath];
    final totalText = _fmtNullableDuration(currentDuration);
    final canPlay = _audioFiles.isNotEmpty;

    final playlistPanel = _LargeDashboardPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.music_note_rounded,
                size: 26,
                color: Color(0xFF111216),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Playlist',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111216),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_audioFiles.length} files loaded',
                      style: const TextStyle(
                        fontSize: 16,
                        color: Color(0xFF6B6D7C),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              _SmallOutlineAction(
                icon: Icons.upload_rounded,
                label: 'Add Files',
                onPressed: _pickAudioFiles,
              ),
              const SizedBox(width: 8),
              _SmallOutlineAction(
                label: 'Clear',
                onPressed: _audioFiles.isEmpty ? null : _clearAudioFiles,
              ),
            ],
          ),
          const SizedBox(height: 28),
          if (_audioFiles.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  'No audio files selected yet.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _audioFiles.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final path = _audioFiles[index];
                  final selected = index == _currentAudioIndex;
                  return _PlaylistTile(
                    index: index + 1,
                    title: _fileName(path),
                    subtitle:
                        '${_fmtNullableDuration(_audioDurations[path])}   •   ${selected ? 'Selected' : 'Ready'}',
                    selected: selected,
                    onTap: () => setState(() => _currentAudioIndex = index),
                  );
                },
              ),
            ),
        ],
      ),
    );

    final controlsPanel = _LargeDashboardPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.music_note_rounded,
                size: 26,
                color: Color(0xFF111216),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Audio Transport Controls',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111216),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Control audio playback and add experiment markers',
                      style: TextStyle(
                        fontSize: 16,
                        color: Color(0xFF6B6D7C),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 30),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFFE9E9EF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Now Playing',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B6D7C),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  currentFile ?? 'No track selected',
                  style: const TextStyle(
                    fontSize: 19,
                    color: Color(0xFF111216),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 12,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              activeTrackColor: const Color(0xFF090716),
              inactiveTrackColor: const Color(0xFFE9E9EF),
              thumbColor: Colors.white,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: math.min(
                _audioPosition.inMilliseconds.toDouble(),
                math.max(1, currentDuration?.inMilliseconds ?? 1).toDouble(),
              ),
              max: math.max(1, currentDuration?.inMilliseconds ?? 1).toDouble(),
              onChanged: currentDuration == null
                  ? null
                  : (v) => _audioPlayer.seek(Duration(milliseconds: v.round())),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _fmtDuration(_audioPosition),
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6B6D7C),
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                totalText == '--:--' ? '0:00' : totalText,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF6B6D7C),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _TransportButton(
                icon: Icons.skip_previous_rounded,
                onPressed: canPlay ? _previousAudio : null,
              ),
              const SizedBox(width: 10),
              _TransportButton(
                icon: _audioPlayer.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                primary: true,
                onPressed: canPlay
                    ? (_audioPlayer.playing
                          ? _pauseAudio
                          : (_audioPaused ? _resumeAudio : _playCurrentAudio))
                    : null,
              ),
              const SizedBox(width: 10),
              _TransportButton(
                icon: Icons.stop_rounded,
                onPressed: canPlay ? _stopAudio : null,
              ),
              const SizedBox(width: 10),
              _TransportButton(
                icon: Icons.skip_next_rounded,
                onPressed: canPlay ? _nextAudio : null,
              ),
              const SizedBox(width: 10),
              _TransportButton(
                icon: Icons.repeat_rounded,
                selected: _loopPlaylist,
                onPressed: () => setState(() => _loopPlaylist = !_loopPlaylist),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.volume_up_outlined, color: Color(0xFF6B6D7C)),

                const SizedBox(width: 12),

                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 13,
                      activeTrackColor: const Color(0xFF090716),
                      inactiveTrackColor: const Color(0xFFE5E5EA),
                      thumbColor: Colors.white,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: _audioPlayer.volume,
                      onChanged: (v) {
                        setState(() {
                          _audioPlayer.setVolume(v);
                        });
                      },
                    ),
                  ),
                ),

                const SizedBox(width: 14),

                Text(
                  '${(_audioPlayer.volume * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B6D7C),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Divider(height: 1, color: Color(0xFFE2E4EA)),
          const SizedBox(height: 20),
          SizedBox(
            height: 42,
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _recordAndEmitMarker('MANUAL_MARKER', 'Manual'),
              icon: const Icon(Icons.flag_outlined, size: 18),
              label: const Text(
                'Add Experiment Marker',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF737684),
                side: const BorderSide(color: Color(0xFFE2E4EA)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              'Markers will be reflected in visualization screens',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF737684),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (isCompact) {
      return Column(
        children: [
          SizedBox(height: 520, child: playlistPanel),
          const SizedBox(height: 18),
          controlsPanel,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 390, height: 520, child: playlistPanel),
        const SizedBox(width: 20),
        Expanded(child: controlsPanel),
      ],
    );
  }

  Widget _rawWaveformPanel() {
    if (!_dataManager.hasData) {
      return const Center(
        child: Text('No raw EEG data yet. Connect and start streaming first.'),
      );
    }
    final fullScale = (_amplitudeScale >= 20 && _amplitudeScale <= 200000)
        ? _amplitudeScale
        : 400.0;
    return Column(
      children: [
        Row(
          children: [
            const Text(
              'Vert Scale',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            _MiniDropdown<double>(
              value:
                  [
                    50.0,
                    100.0,
                    200.0,
                    400.0,
                    1000.0,
                    10000.0,
                    50000.0,
                    200000.0,
                  ].contains(fullScale)
                  ? fullScale
                  : 400.0,
              items: const [
                50.0,
                100.0,
                200.0,
                400.0,
                1000.0,
                10000.0,
                50000.0,
                200000.0,
              ],
              label: (v) => '${v.toStringAsFixed(0)} uV',
              onChanged: _onAmplitudeScaleChanged,
            ),
            const SizedBox(width: 20),
            const Text(
              'Window',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            _MiniDropdown<double>(
              value: [1.0, 2.0, 5.0, 10.0].contains(_timeWindowSeconds)
                  ? _timeWindowSeconds
                  : 5.0,
              items: const [1.0, 2.0, 5.0, 10.0],
              label: (v) => '${v.toStringAsFixed(0)} sec',
              onChanged: _onTimeWindowChanged,
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: StackedEEGChart(
            channelData: _dataManager.allChannelData,
            timeWindowSeconds: _timeWindowSeconds,
            fullScaleUv: fullScale,
            markers: _markers,
          ),
        ),
      ],
    );
  }

  int _dataPointCount() =>
      _dataManager.allChannelData.fold(0, (sum, q) => sum + q.length);

  double _avgPower() {
    final vals = [
      _deltaRaw,
      _thetaRaw,
      _alphaRaw,
      _betaRaw,
      _gammaRaw,
    ].where((v) => v.isFinite && v > 0).toList();
    if (vals.isEmpty) return 0;
    return vals.reduce((a, b) => a + b) / vals.length;
  }

  String _peakBand() {
    final values = {
      'Delta': _deltaRaw,
      'Theta': _thetaRaw,
      'Alpha': _alphaRaw,
      'Beta': _betaRaw,
      'Gamma': _gammaRaw,
    };
    var best = 'Delta';
    var bestValue = values[best] ?? 0;
    values.forEach((band, value) {
      if (value > bestValue) {
        best = band;
        bestValue = value;
      }
    });
    return bestValue <= 0 ? 'Delta' : best;
  }

  Future<void> _openUserWindow() async {
    try {
      // If we think a participant window already exists, try to ping it.
      // If it fails, the window was probably closed, so clear the old ID.
      if (_userWindowId != null) {
        try {
          await DesktopMultiWindow.invokeMethod(
            _userWindowId!,
            'bandPowerUpdate',
            _currentUserWindowPayload(),
          );
          return;
        } catch (e) {
          print('Old participant window is no longer available: $e');
          _userWindowId = null;
        }
      }

      final window = await DesktopMultiWindow.createWindow(
        jsonEncode({'type': 'user_window'}),
      );

      _userWindowId = window.windowId;

      await window.setFrame(const Offset(1200, 120) & const Size(720, 620));
      await window.setTitle('Participant Control');
      await window.show();

      await Future.delayed(const Duration(milliseconds: 300));
      await _sendBandPowerToUserWindow();

      print('User window opened: $_userWindowId');
    } catch (e) {
      print('Failed to open user window: $e');

      _userWindowId = null;

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open participant window: $e')),
      );
    }
  }

  Map<String, dynamic> _currentUserWindowPayload() {
    return {
      'delta': _deltaRaw,
      'theta': _thetaRaw,
      'alpha': _alphaRaw,
      'beta': _betaRaw,
      'gamma': _gammaRaw,
      'volume': math.min(_audioPlayer.volume, 0.8),
    };
  }

  Future<void> _sendBandPowerToUserWindow() async {
    if (_userWindowId == null) return;

    try {
      await DesktopMultiWindow.invokeMethod(
        _userWindowId!,
        'bandPowerUpdate',
        _currentUserWindowPayload(),
      );
    } catch (e) {
      print('Participant window closed or unavailable: $e');
      _userWindowId = null;
    }
  }

  void _setupUserWindowMessageHandler() {
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'setVolume') {
        final data = Map<String, dynamic>.from(call.arguments);
        final volume = (data['volume'] as num).toDouble();

        await _audioPlayer.setVolume(volume.clamp(0.0, 0.8));

        if (mounted) {
          setState(() {});
        }

        await _sendBandPowerToUserWindow();
      }

      return null;
    });
  }
}

class _TopPillTabs extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _TopPillTabs({required this.selectedIndex, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
    width: 360,
    height: 34,
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xFFE8E8EC),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Row(
      children: [
        Expanded(
          child: _PillTabButton(
            text: 'Main Dashboard',
            selected: selectedIndex == 0,
            onTap: () => onChanged(0),
          ),
        ),
      ],
    ),
  );
}

class _PillTabButton extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;

  const _PillTabButton({
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(15),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
          color: const Color(0xFF111216),
        ),
      ),
    ),
  );
}

class _LargeDashboardPanel extends StatelessWidget {
  final Widget child;

  const _LargeDashboardPanel({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE0E2E8)),
    ),
    child: child,
  );
}

class _SmallOutlineAction extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback? onPressed;

  const _SmallOutlineAction({
    this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 38,
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 17),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF111216),
        disabledForegroundColor: const Color(0xFFB0B3BD),
        side: const BorderSide(color: Color(0xFFE0E2E8)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: EdgeInsets.symmetric(horizontal: icon == null ? 18 : 14),
      ),
    ),
  );
}

class _PlaylistTile extends StatelessWidget {
  final int index;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _PlaylistTile({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFF8F8FB) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? const Color(0xFFC9CBD4) : const Color(0xFFE0E2E8),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.drag_indicator_rounded,
            size: 18,
            color: Color(0xFF777A88),
          ),
          const SizedBox(width: 10),
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFD7D7DE),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              '$index',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w900,
                color: Color(0xFF111216),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111216),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B6D7C),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _TransportButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool selected;

  const _TransportButton({
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: primary ? 52 : 42,
    height: primary ? 52 : 42,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        elevation: 0,
        padding: EdgeInsets.zero,
        backgroundColor: primary || selected
            ? const Color(0xFF777784)
            : Colors.white,
        foregroundColor: primary || selected
            ? Colors.white
            : const Color(0xFF737684),
        disabledBackgroundColor: const Color(0xFFF8F8FA),
        disabledForegroundColor: const Color(0xFFB8BBC5),
        side: BorderSide(
          color: primary || selected
              ? const Color(0xFF777784)
              : const Color(0xFFE0E2E8),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: Icon(icon, size: primary ? 25 : 21),
    ),
  );
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final Widget? footer;
  const _DashboardCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.footer,
  });
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFD9DCE3)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111216),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF69707D),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 14),
        child,
        if (footer != null) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFE9E9EF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: footer!,
          ),
        ],
      ],
    ),
  );
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color tint;
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.tint,
  });
  @override
  Widget build(BuildContext context) => Container(
    height: 72,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFD9DCE3)),
    ),
    child: Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: tint.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: tint, size: 17),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF69707D),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111216),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _StatusBadge extends StatelessWidget {
  final String text;
  final bool active;
  const _StatusBadge({required this.text, required this.active});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: active ? const Color(0xFFE8F8EF) : const Color(0xFFF1F1F4),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: active ? const Color(0xFFB7E4C7) : const Color(0xFFD9DCE3),
      ),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        color: active ? const Color(0xFF0F7A3C) : const Color(0xFF404651),
      ),
    ),
  );
}

class _MiniDarkBadge extends StatelessWidget {
  final String text;
  const _MiniDarkBadge({required this.text});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFF090716),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _DashboardButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool dark;
  const _DashboardButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.dark = false,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 34,
    width: double.infinity,
    child: ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14),
      label: Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
      ),
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: dark ? const Color(0xFF080615) : Colors.white,
        foregroundColor: dark ? Colors.white : const Color(0xFF111216),
        disabledBackgroundColor: const Color(0xFFF2F2F5),
        disabledForegroundColor: const Color(0xFF9CA3AF),
        side: BorderSide(
          color: dark ? const Color(0xFF080615) : const Color(0xFFD9DCE3),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    ),
  );
}

class _StreamPicker extends StatelessWidget {
  final List<StreamInfo> streams;
  final int? selectedIndex;
  final String fallbackName;
  final VoidCallback onSearchStreams;
  final ValueChanged<int> onSelected;
  const _StreamPicker({
    required this.streams,
    required this.selectedIndex,
    required this.fallbackName,
    required this.onSearchStreams,
    required this.onSelected,
  });
  @override
  Widget build(BuildContext context) {
    if (streams.isEmpty) {
      return InkWell(
        onTap: onSearchStreams,
        child: Container(
          height: 34,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F1F4),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            fallbackName,
            style: const TextStyle(fontSize: 12, color: Color(0xFF111216)),
          ),
        ),
      );
    }
    final safeIndex =
        selectedIndex != null &&
            selectedIndex! >= 0 &&
            selectedIndex! < streams.length
        ? selectedIndex!
        : 0;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F1F4),
        borderRadius: BorderRadius.circular(5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: safeIndex,
          isExpanded: true,
          iconSize: 18,
          items: List.generate(
            streams.length,
            (i) => DropdownMenuItem(
              value: i,
              child: Text(
                streams[i].name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          onChanged: (i) {
            if (i != null) onSelected(i);
          },
        ),
      ),
    );
  }
}

class _AudioDropdown extends StatelessWidget {
  final List<String> audioFiles;
  final int currentIndex;
  final String Function(String) fileNameForPath;
  final ValueChanged<int> onChanged;
  const _AudioDropdown({
    required this.audioFiles,
    required this.currentIndex,
    required this.fileNameForPath,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    if (audioFiles.isEmpty) {
      return Container(
        height: 34,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F1F4),
          borderRadius: BorderRadius.circular(5),
        ),
        child: const Text('No Audio', style: TextStyle(fontSize: 12)),
      );
    }
    final safeIndex = currentIndex >= 0 && currentIndex < audioFiles.length
        ? currentIndex
        : 0;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F1F4),
        borderRadius: BorderRadius.circular(5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: safeIndex,
          isExpanded: true,
          iconSize: 18,
          items: List.generate(
            audioFiles.length,
            (i) => DropdownMenuItem(
              value: i,
              child: Text(
                fileNameForPath(audioFiles[i]),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          onChanged: (i) {
            if (i != null) onChanged(i);
          },
        ),
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool active;
  const _ChannelChip({required this.label, required this.active});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: active ? const Color(0xFFEFF6FF) : const Color(0xFFE9E9ED),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      children: [
        Icon(
          active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          size: 13,
          color: active ? const Color(0xFF2563EB) : const Color(0xFF9CA3AF),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF111216)),
        ),
      ],
    ),
  );
}

class _EventTimeline extends StatelessWidget {
  final List<StimulusMarker> markers;
  const _EventTimeline({required this.markers});
  @override
  Widget build(BuildContext context) {
    if (markers.isEmpty) {
      return const SizedBox(
        height: 92,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'No events recorded yet. Start the experiment to begin tracking.',
            style: TextStyle(fontSize: 12, color: Color(0xFF69707D)),
          ),
        ),
      );
    }
    final recent = markers.reversed.take(6).toList();
    return SizedBox(
      height: 112,
      child: ListView.separated(
        itemCount: recent.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final marker = recent[index];
          return Row(
            children: [
              const Icon(Icons.circle, size: 7, color: Color(0xFF111216)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  marker.displayLabel,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${marker.graphTimeSeconds.toStringAsFixed(1)}s',
                style: const TextStyle(fontSize: 11, color: Color(0xFF69707D)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SegmentSwitch extends StatelessWidget {
  final int selectedIndex;
  final String leftText;
  final String rightText;
  final ValueChanged<int> onChanged;
  const _SegmentSwitch({
    required this.selectedIndex,
    required this.leftText,
    required this.rightText,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Container(
    height: 28,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: const Color(0xFFE8E8EC),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        Expanded(
          child: _SegmentItem(
            text: leftText,
            selected: selectedIndex == 0,
            onTap: () => onChanged(0),
          ),
        ),
        Expanded(
          child: _SegmentItem(
            text: rightText,
            selected: selectedIndex == 1,
            onTap: () => onChanged(1),
          ),
        ),
      ],
    ),
  );
}

class _SegmentItem extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _SegmentItem({
    required this.text,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Color(0xFF111216),
        ),
      ),
    ),
  );
}

class _MiniDropdown<T extends num> extends StatelessWidget {
  final T value;
  final List<T> items;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  const _MiniDropdown({
    required this.value,
    required this.items,
    required this.label,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Container(
    height: 30,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFFD9DCE3)),
      borderRadius: BorderRadius.circular(5),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: value,
        isDense: true,
        items: items
            .map(
              (v) => DropdownMenuItem<T>(
                value: v,
                child: Text(label(v), style: const TextStyle(fontSize: 12)),
              ),
            )
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    ),
  );
}
