# Changelog

Versions of the MW75 Bench app (`example/`) and, in brackets, of the
`mw75_neuro` package it ships with. Releases are tagged `mw75-bench-v<version>`.

## Unreleased

- **Sound level**: the oddball tones' level can be set. A step-by-step calibration with a
  sound level meter (per output, at a fixed Mac volume) lets it be set in dB SPL, with
  each tone frequency measured separately and checked levels kept as quick picks.
  Uncalibrated outputs use a level relative to the loudest the app plays. The app
  notices when the Mac volume moves from the calibrated one and can set it back.
- **Oddball settings**: rare (deviant) share from 10% to 30%, tone length from 50 to
  200 ms, and the time between tones (ISI, shortest and longest).
- **Average response**: a table of trials used and rejected for standard and rare
  tones, with the reasons; a baseline window that can be switched or dragged out on
  the plot (the averages, channel plots and tests follow); and a readout of each trace
  under the pointer.
- Runs record the level, ISI, tone length and rare share they used; runs saved by
  1.1.0 still load.
- Menu items under the pointer are easier to see. The app stays light in macOS dark
  mode.

## MW75 Bench 1.1.0 (mw75_neuro 0.2.0)

- **Your focus**: a personal focus score from the raw EEG. A calibration alternates
  resting with silently counting backwards in sevens; a shrinkage LDA on per-channel
  theta, alpha and low-beta shares learns the difference, with block-wise
  cross-validation shown as Good / Fair / Unreliable. Windows with Bluetooth loss or
  artifacts are not scored, and the page says why. Published to LSL as "MW75 Focus".
- Feedback shown as a flame or a rocket beside the number and bar, with a personal
  target (30th percentile of the last 3 minutes, between 40 and 85); sparks and
  altitude reward time at or above it. Still pictures when Reduce Motion is on.
- The side panel is a drawer that can be hidden.
- Calibrations saved by 1.0.0 are not read (the model format changed): calibrate again.

## MW75 Bench 1.0.0 (mw75_neuro 0.1.0)

- Raw 12-channel EEG over Bluetooth with start/stop, signal quality and an LSL outlet
  compatible with Neurable Research Kit.
- Live signals: high-pass, mains notch and optional band-pass filters, per-channel
  spectrum, band power, and a scrolling EEG view with fixed or automatic scale.
- Auditory oddball (P300) and eyes-closed alpha tests with saved runs.
