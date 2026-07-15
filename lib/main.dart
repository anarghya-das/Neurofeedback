import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'screens/eeg_viewer_screen.dart';
import 'screens/user_window.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();

  JustAudioMediaKit.ensureInitialized(
    windows: true,
    linux: false,
  );

  if (args.isNotEmpty && args.first == 'multi_window') {
    final windowId = int.parse(args[1]);
    final argument = args.length > 2 ? args[2] : '{}';

    runApp(UserWindowApp(windowId: windowId, argument: argument));
  } else {
    runApp(const MainApp());
  }
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: EEGViewer(title: 'EEG Viewer'),
    );
  }
}