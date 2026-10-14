---
name: flutter-skill
description: "Launch, look at and drive the MW75 Bench app (packages/mw75_neuro/example) through the flutter-skill MCP server: screenshots, tapping, typing, scrolling, reading the UI tree and logs. Use when asked to run, test, check or demo the app's UI, or to confirm a change works in the real app rather than only in widget tests."
---

# Driving MW75 Bench with flutter-skill

[flutter-skill](https://github.com/ai-dashboad/flutter-skill) (MIT) is an MCP server
that connects to a running Flutter app in debug mode. The MW75 Bench app starts its
bridge in `main()` when `kDebugMode` is true (`FlutterSkillBinding.ensureInitialized()`),
so release builds and the DMG do not include it.

## Setup (already done in this repo)

- App dependency: `flutter_skill` in `packages/mw75_neuro/example/pubspec.yaml`.
- MCP server: `.mcp.json` at the repo root runs `${HOME}/.pub-cache/bin/flutter_skill server`.
- On a new machine, install the server once with
  `dart pub global activate flutter_skill` (not npm). CocoaPods is needed to build
  for macOS: `brew install cocoapods`.
- Claude Code asks to approve the project's MCP server the first time; tools appear
  as `mcp__flutter-skill__*` after that (restart the session if they do not).

Do not run `flutter-skill init`: it writes MCP config to `~/.claude/settings.json`,
which Claude Code does not read, and the app is already set up.

## Launch and connect

Prefer the MCP tool:

```
launch_app(project_path: "<repo>/packages/mw75_neuro/example", device_id: "macos",
           extra_args: ["--vm-service-port=50000"])
```

If the app is already running in debug mode, use `scan_and_connect()` instead.
Do not pass `project_path` to `scan_and_connect` or `connect_app`: its "auto-fix"
edits `pubspec.yaml` and `main.dart`.

`launch_app` (flutter_skill 0.9.37) builds and starts the app but then fails with
E303 "Unsupported URL scheme 'http'", because it tries to connect to the
`http://127.0.0.1:50000/<token>=/` URI. The app is fine; connect by hand with that
token in WebSocket form:

```
connect_app(uri: "ws://127.0.0.1:50000/<token>=/ws")
```

**First launch of a new debug build:** macOS asks "MW75 Bench would like to use
Bluetooth". The app lists paired headsets at start-up and waits on that dialog, so
nothing responds until someone clicks Allow. If the app seems frozen right after
launch, ask the user to check for the dialog.

## Core loop

1. `screenshot()`: see the current window (Read the returned file path to view it).
2. `inspect()`: list tappable elements with their text, widget type and centre.
3. `tap(text: "Auditory oddball")`, or `tap(x: ..., y: ...)` with an `inspect()`
   centre for icon-only buttons.
4. `screenshot()` again to confirm the UI responded.

**Do not use `inspect_interactive()` or `snapshot()`.** In flutter_skill 0.9.37 both
crash on every screen that has a typed `DropdownButton<String>` (all of this app's
screens do): "type '(String?) => void' is not a subtype of type '((dynamic) => void)?'"
at `flutter_skill.dart:2763`. The package reads `onChanged` through a
`DropdownButton<dynamic>` type. `inspect()` does not go through that code. Without
`inspect_interactive()` there are no `ref`s, so target elements by visible `text`,
then by `key`, and by coordinates last. After navigating, use
`wait_for_element(...)`. If nothing is found, take a screenshot and call `get_logs()`.

Tool calls show a "Tapping" banner across the top of the window; it is the
package's test indicator, not part of the app. `enable_test_indicators(enabled: false)`
hides it for clean screenshots.

flutter-skill's taps arrive as touch input, so the app switches to touch focus mode,
which draws focus highlights differently from a mouse. To see what a mouse user
sees, or to flip the app between light and dark without changing the Mac, call the
Dart VM service (the `ws://…/ws` URI) directly: `evaluate` in the root library
`FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional`,
and call `ext.flutter.brightnessOverride` with `value=Brightness.light`,
`Brightness.dark`, or `null` to go back to following the system.

## App map

- Top tabs: **Live signals**, **Auditory oddball**, **Eyes-closed alpha**, **Your focus**.
- Side panel (can be hidden): headset start/stop, signal quality, filters, LSL stream.
- Auditory oddball, left column: output picker, **Sound level** (Calibrate… opens a
  3-step dialog), rare tone, rare (deviant) share, tone length, ISI (shortest and
  longest), tones per run, rejection threshold, high-pass, Preview and Start test,
  and the list of saved runs (tick one to include it in the results).
- Auditory oddball, right column: average response with the baseline picker (drag
  across the plot before 0 ms to set a custom window), test tiles, **Trials used**
  table, and per-channel plots.

## Cautions

- **Preview**, **Start test** and the calibration dialog's **Play** make real sound on
  the chosen output. Keep levels low, and tell the user before playing anything.
- Starting raw EEG needs the MW75 headset on and connected; without it, tests stay
  blocked with "Start raw EEG first".
- Saving a calibration writes `~/Documents/MW75 Tests/sound calibration.json`, which the
  user's real measurements live in. Do not save or remove calibrations unless asked.
- Do not change the Mac volume ("Set volume to …") unless asked.

## Useful tools

| Tool | Use |
|------|-----|
| `screenshot` | Capture the window |
| `inspect` | Tappable elements with text, type and centre (use instead of `inspect_interactive`) |
| `tap`, `long_press`, `drag`, `scroll`, `swipe` | Pointer actions |
| `enter_text`, `set_text`, `clear_text`, `get_text` | Text fields |
| `find_element`, `wait_for_element`, `get_elements` | Inspection |
| `press_key` | Keyboard (e.g. Return to submit a number field) |
| `hot_reload`, `hot_restart` | Apply code changes |
| `get_logs`, `clear_logs` | App output, including `[bench]` status lines |
