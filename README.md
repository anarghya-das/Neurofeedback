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
| `lib/` | The app (UI shell, entry point `lib/main.dart`) |
| `packages/mw75_neuro/` | Driver and shared logic used by the app: transport/protocol, signal processing, test runs, UI panels, and the native plugin code (`macos/`) |
| `macos/` | macOS runner for the app |
| `scripts/package_macos.sh` | Builds and packages a macOS DMG into `dist/` |
| `docs/` | Protocol notes (`neurable-mw75-protocol.md`) |
| `tools/` | Python/Swift helpers for probing the headset and reading LSL streams |

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
cd packages/mw75_neuro && flutter test   # driver and shared logic (the app has no tests of its own yet)
```

See `packages/mw75_neuro/CHANGELOG.md` for version history.
