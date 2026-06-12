import 'package:flutter/material.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../widgets/band_power_bar_chart.dart';

class UserWindowApp extends StatelessWidget {
  final int windowId;
  final String argument;

  const UserWindowApp({
    super.key,
    required this.windowId,
    required this.argument,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: UserControlWindow(windowId: windowId),
    );
  }
}

class UserControlWindow extends StatefulWidget {
  final int windowId;

  const UserControlWindow({
    super.key,
    required this.windowId,
  });

  @override
  State<UserControlWindow> createState() => _UserControlWindowState();
}

class _UserControlWindowState extends State<UserControlWindow> {
  double _volume = 1.0;

  double _delta = 0;
  double _theta = 0;
  double _alpha = 0;
  double _beta = 0;
  double _gamma = 0;

  @override
  void initState() {
    super.initState();

    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'bandPowerUpdate') {
        final data = Map<String, dynamic>.from(call.arguments);

        if (!mounted) return null;

        setState(() {
          _delta = (data['delta'] as num).toDouble();
          _theta = (data['theta'] as num).toDouble();
          _alpha = (data['alpha'] as num).toDouble();
          _beta = (data['beta'] as num).toDouble();
          _gamma = (data['gamma'] as num).toDouble();
          _volume = (data['volume'] as num).toDouble();
        });
      }

      return null;
    });
  }

  Future<void> _sendVolumeToMain(double value) async {
    await DesktopMultiWindow.invokeMethod(
      0,
      'setVolume',
      {
        'volume': value,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Participant Control',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111216),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Audio volume and live EEG band power',
                style: TextStyle(
                  fontSize: 14,
                  color: Color(0xFF6B6D7C),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 30),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE0E2E8)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Volume',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111216),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(
                          Icons.volume_down_rounded,
                          color: Color(0xFF6B6D7C),
                        ),
                        Expanded(
                          child: Slider(
                            value: _volume.clamp(0.0, 1.0),
                            min: 0,
                            max: 1,
                            onChanged: (value) {
                              setState(() {
                                _volume = value;
                              });

                              _sendVolumeToMain(value);
                            },
                          ),
                        ),
                        const Icon(
                          Icons.volume_up_rounded,
                          color: Color(0xFF6B6D7C),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${(_volume * 100).round()}%',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111216),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE0E2E8)),
                  ),
                  child: BandPowerBarChart(
                    delta: _delta,
                    theta: _theta,
                    alpha: _alpha,
                    beta: _beta,
                    gamma: _gamma,
                    baselineDelta: null,
                    baselineTheta: null,
                    baselineAlpha: null,
                    baselineBeta: null,
                    baselineGamma: null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}