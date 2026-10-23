# MW75 Bench (Neurofeedback)

A Flutter desktop app for testing whether wearable, non-invasive EEG can drive
reliable neurofeedback, including in audiology research (tinnitus, hearing
loss, misophonia, hyperacusis). It currently supports the Neurable MW75 Neuro
headphones and provides:

- headset connection, start/stop streaming and signal quality
- live EEG plot, filters and spectrum
- focus feedback (neurofeedback) with calibration
- auditory oddball and eyes-closed alpha test runs, with sound-level calibration
- Lab Streaming Layer (LSL) outlets for EEG, focus and oddball markers

## Layout

| Path | What it is |
| --- | --- |
| `lib/main.dart` | App entry point and window layout |
| `lib/mw75_neuro.dart`, `lib/src/` | Headset driver and shared logic: transport/protocol, signal processing, test runs, LSL outlets, UI panels |
| `macos/` | macOS runner. The native Swift code for Bluetooth and tone playback is in `macos/Runner/` (`Mw75NeuroPlugin`, `BleLink`, `ToneStimulator`) and is registered in `MainFlutterWindow.swift` |
| `test/` | Unit and widget tests |
| `scripts/package_macos.sh` | Builds and packages a macOS DMG into `dist/` |
| `docs/` | Protocol notes (`neurable-mw75-protocol.md`, `emotiv-epoc-plus.md`) and the plan for supporting more headsets (`multi-device-plan.md`) |
| `tools/` | Python/Swift helpers for probing headsets (`mw75_probe/`, `emotiv_probe/`) and reading LSL streams |

The previous "EEG Viewer LSL" app is no longer in this tree; it remains on the
`main` branch history from before this restructure.

## Run

```sh
flutter pub get
flutter run -d macos
```

Requires a Flutter beta that satisfies the SDK constraint in `pubspec.yaml`,
and macOS 14+. Windows support is in progress.

## Test

```sh
flutter test
```

See `CHANGELOG.md` for version history.
