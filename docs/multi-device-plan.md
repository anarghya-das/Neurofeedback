# Plan: more headsets, starting with the Emotiv EPOC+

**Goal:** the app connects to more than one EEG headset, and the live signals,
filters, LSL stream and tests work the same way on each. The Emotiv EPOC+ comes
first, read through its USB dongle without Emotiv software
([emotiv-epoc-plus.md](emotiv-epoc-plus.md)).

**Status (branch `feature/emotiv-epoc-plus`):** the dongle is found and opens from
this Mac, and the decryption is confirmed (from an earlier session, headset off the
head). Docs and `tools/emotiv_probe/check.py` are in place. No app code yet.

## Where the app assumes an MW75

The driver was written for one headset, so MW75 facts are spread through it:

| Assumption | Where | What changes |
|---|---|---|
| The device *is* an `Mw75Headset` | `main.dart`, `oddball.dart`, `alpha_test.dart`, `focus_session.dart`, `ui/headset_panel.dart`, `ui/filter_panel.dart` | Depend on a common `EegDevice` interface instead |
| 12 EEG channels | `Mw75Protocol.eegChannelCount` used as the default in `band_power.dart`, `alpha_test.dart`, `focus_metric.dart`, `erp.dart`, `focus_session.dart`, `signal_quality.dart`; `MainsTracker(channels: 12)` | Channel count comes from the device |
| 500 Hz | `Mw75Protocol.samplingRate` fallback in tests; ERP resampling grid fixed at 500 Hz (`erp.dart`); 512-sample spectra (about 1 s at 500 Hz, 4 s at 128 Hz) | Rate from the device; windows defined in seconds |
| High-pass coefficient for 500 Hz | `_FirstOrderHighPass._alpha` in `eeg_filters.dart` | Compute from the rate; keep Research Kit's exact value at 500 Hz |
| Spectra up to 100 Hz | `EegBand.gamma` (32–100 Hz) and the 0.5–100 Hz total in `band_power.dart` | Cap at half the sample rate (64 Hz on the EPOC+) |
| Counter wraps at 256 | `Mw75StreamProcessor` (`& 0xFF`, the 0.5 s long-dropout rule) | Wrap passed in (EPOC+: 128, so a long dropout is 1 s) |
| Sample layout `[Ch1..Ch12, Ref, DRL, counter, status]` | `Mw75Sample`, LSL channel list in `headset.dart` | EEG channels first, then device-specific extras; the device says how many are EEG |
| Ear-cup montage | `Mw75Montage`, `EarSide`, `_ChannelSet` in `main.dart`, `ear_cup_map.dart`, `cup_contact.dart` | Montage supplied by the device: channel groups, ERP and alpha defaults, a layout for the contact map |
| Contact quality from 24-bit ADC clipping and Ref/DRL | `Mw75SignalQualityEstimator` | Per-device estimator, same `ContactQuality` ratings |
| MW75-only features | Neurable Focus (BLE metrics mode), cup contact level, GAIA commands, checksum errors, firmware version | Stay on `Mw75Headset`; the UI shows them only for that device |

Already device-neutral: `LslEegOutlet` (takes any channel list), the native
LSL-clock timestamps (`CLOCK_MONOTONIC_RAW`), `TestRunStore`, the filter maths in
`biquad.dart`, and the tone output.

## Design

**`EegDevice` (abstract, a `ChangeNotifier`).** It covers what the tests and
panels use today: `state`, `statusText`, `warning`, the device list
(`devices`, `selectedDevice`, `refreshDevices`, `selectDevice`), `start`/`stop`,
`samples`, `effectiveRate`, loss statistics (`packetsReceived`, `packetsLost`,
`lossRatio`, `recentLossRatio`, `longDropouts`, `packetRate`), `quality`,
`batteryPercent`, `filters`, `mainsHz`, `interpolate`, LSL settings
(`publishToLsl`, `streamName`, `lslHasConsumers`) and `log`. Plus a
`DeviceDescription`: name, channel labels, nominal rate, EEG channel count,
montage and capability flags (has Ref/DRL, has on-device focus, has motion).
`Mw75Headset` implements it unchanged; `EmotivEpocPlus` is the second
implementation.

**`EegSample`** replaces `Mw75Sample` (same fields: `values`, `raw`, `time`,
`status`). Consumers already loop over channel indexes, so they only need the
count.

**Emotiv transport (Swift).** Add HID to the existing plugin
(`macos/Runner/Mw75NeuroPlugin.swift`): `IOHIDManager` matching VID `0x1234` /
PID `0xED02`, usage page `0xFFFF`, usage 2; an input-report callback that stamps
each 32-byte report with the LSL clock and sends it on the existing event
channel. New methods: `hidDevices`, `hidOpen`, `hidClose`. The app is not
sandboxed, so no new entitlement is needed (a sandboxed build would need
`com.apple.security.device.usb`).

**Decrypt and parse in Dart, not Swift.** The MW75 driver already works this way:
Swift moves bytes and Dart holds the protocol. That keeps key derivation,
decryption, parsing, gap filling and quality covered by `flutter test`, using
recorded encrypted reports as fixtures. It needs a pure-Dart AES-ECB (for
example `pointycastle`). The alternative, CommonCrypto in Swift, adds no Dart
dependency but leaves the decryption untested.

**Emotiv signal quality.** Computed from µV over 1 s windows: flat (no skin
contact), railing or very large swings, slow drift, mains-to-signal ratio, plus
dropped packets. Thresholds are set from worn recordings. If worn captures show
real contact-quality bytes, use them instead.

**LSL.** One stream per device. EPOC+: `EmotivEPOCPlus`, type `EEG`, 14 channels in
µV with their electrode labels, then `counter` and `sampleStatus`, nominal 128 Hz.

**Windows later.** Keep the transport surface small (list, open, a stream of
timestamped reports, close), so a Windows HID implementation can be added on the
`windows-support` branch without touching the Dart side.

## Phases

Each phase is a separate PR into `dev`.

1. **Verify on the head** (needs the headset worn with damp pads):
   - Channel order: blinks at AF3/AF4, eyes-closed alpha at O1/O2, jaw clench on
     the temporal channels.
   - Contact-quality and battery bytes while worn; watch byte 16 over a session.
   - Motion axes: tilt and rotate the headset.
   - Add `--save` to the check script and record about 60 s of encrypted reports,
     worn and off the head, as test fixtures.
   - Update `emotiv-epoc-plus.md` with the results.
2. **Device abstraction, MW75 only.** Introduce `EegDevice`, `EegSample` and
   `DeviceDescription`, and pass channel count, rate, counter wrap and montage
   through. No visible change: all tests pass and the MW75 behaves exactly as
   before, checked on the headset.
3. **Emotiv driver.** Swift HID transport, plus Dart `EmotivEpocPlus`: key, AES,
   parser, stream processor with wrap 128, LSL outlet and quality estimator.
   Unit tests run on the fixtures from phase 1.
4. **UI.** Device type picker in the Headset panel; a 14-electrode head map in place
   of the ear cups; MW75-only panels hidden for other devices. The live plot,
   spectrum, band power and filters work on the EPOC+.
5. **Tests on the EPOC+.** Eyes-closed alpha first (O1/O2 are on the headset). Then
   the auditory oddball, once its channels are chosen. Your focus needs its own
   calibration per device. Saved runs and calibrations record the device, its
   channel labels and rate, so runs from different headsets are never pooled;
   existing runs are read as MW75.

## Decisions for you

- **Oddball channels on the EPOC+.** It has no Pz, where the P300 is largest. The
  nearest are P7/P8 and O1/O2.
- **128 Hz or 256 Hz.** 128 Hz is enough for the alpha test (up to 40 Hz), the P300
  (20 Hz low-pass) and the focus metric (up to 45 Hz); only the band-power panel's
  gamma band is cut to 32–64 Hz. Getting 256 Hz back needs CyKit on Windows on an
  untested firmware, so I'd stay at 128 Hz.
- **Which headset after the Emotiv.** It decides how general the transport needs to
  be (HID, BLE or a vendor SDK such as BrainFlow's boards).
- **Names.** The app is "MW75 Bench" and the Dart package is `mw75_neuro`, and runs
  save to `~/Documents/MW75 Tests`. These can be renamed once a second device works;
  the run folder would need a migration or a fallback.
