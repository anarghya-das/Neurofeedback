# Neurable MW75 Neuro — start/stop and signal-quality protocol

Extracted by static analysis of Neurable **Research Kit 1.1.3** (macOS, arm64,
`/Applications/Research Kit.app/Contents/MacOS/research_kit`). The binary is a
Tauri (Rust) app with an unstripped C++/Obj-C core (`ProtocolMW75`, `Listener`,
`MacListener`, `BluetoothClient`). Nothing here has been verified against a
headset yet. Treat byte values as "what Research Kit sends", not as an official
spec.

## Transports

| Purpose | Link | Details |
|---|---|---|
| Commands (research/raw mode) | Classic BT RFCOMM | Channel found by SDP lookup of the Serial Port Profile UUID `00001101-0000-1000-8000-00805F9B34FB` on the headset's BT address |
| Raw EEG data | Classic BT RFCOMM | Fixed **channel 25** |
| Commands + data (on-device "metrics" mode only) | BLE | Service `00001100-D102-11E1-9B23-00025B00A5A5`, write `…1101-…A5A5`, notify `…1102-…A5A5`, data `…1103-…A5A5`, EEG data `00001105-D102-11E1-9B23-00025B00A5A6` |

Research Kit picks the mode from `ConnectionOptions` (`+0x9c == 1` → metrics/BLE,
otherwise raw/RFCOMM). LSL streaming uses the **raw/RFCOMM** path.

## Command framing

RFCOMM commands: `FF 04 00 <len> 09 9A 03 <cmdId> <payload[len]>`.
Bytes go out verbatim. The reply is matched on byte index 7 (`cmdId`).

| Name | Bytes |
|---|---|
| GET_EEG_MODE | `FF 04 00 01 09 9A 03 49 FF` |
| ENABLE_EEG | `FF 04 00 01 09 9A 03 60 01` |
| ENABLE_RAW_MODE | `FF 04 00 01 09 9A 03 41 01` |
| DISABLE_RAW_MODE | `FF 04 00 01 09 9A 03 41 00` |
| GET_CURRENT_STATE | `FF 04 00 01 09 9A 03 79 FF` |
| GET_BATTERY_LEVEL | `FF 04 00 01 09 9A 03 14 FF` |
| GET_CLOCK | `FF 04 00 01 09 9A 03 32 FF` |
| UPDATE_CLOCK (prefix, + 6 payload bytes) | `FF 04 00 06 09 9A 03 31` |
| GET_CONNECTED_DEVICES_COUNT | `FF 04 00 01 09 9A 03 1E FF` |
| GET_RAW_EEG_FEATURE_STATUS | `FF 04 00 01 09 9A 03 6B FF` |
| GET_LICENSE | `FF 04 00 01 09 9A 03 6A FF` |
| GET_STM32_UUID | `FF 04 00 01 09 9A 03 69 FF` |
| GET_MD_SERIAL_NUMBER | `FF 04 00 01 09 9A 03 24 FF` |
| GET_APPLICATION_VERSION | `FF 04 00 00 00 1D 00 05` |

BLE (metrics mode) commands have no `FF 04 00 <len>` prefix:

| Name | Bytes | Success |
|---|---|---|
| START_SESSION | `09 9A 03 35 04` | `resp[4] == 0xF1` |
| STOP_SESSION | `09 9A 03 36 FF` | `resp[4] == 0xF1` |
| GET_CLOCK_BLE / UPDATE_CLOCK_BLE | `09 9A 03 32` / `09 9A 03 31` + payload | |
| SET_CALIBRATION | `09 9A 03 7C E1 B6 27 3E 20 3D D1 3E 14 00 1E 00 0A 00` | |
| GET_LAST_SESSION_ID | `09 9A 03 3C 00` | |

## Start sequence (raw mode, `Listener::init` → `sendStartCommands`)

1. Open the RFCOMM command channel (SDP/SPP), then the RFCOMM data channel 25.
2. Pre-checks (warnings only): connected-device count (warns if the headset is
   attached to another machine), battery level, firmware version.
3. If the device is not already streaming raw data, Research Kit validates the
   license (`GET_MD_SERIAL_NUMBER`, `GET_STM32_UUID`, `GET_RAW_EEG_FEATURE_STATUS`)
   and aborts on failure. The details of this check were not traced.
4. `GET_EEG_MODE`. EEG counts as enabled when `resp.length >= 10 && resp[9] == 1`.
   If it isn't enabled, send `ENABLE_EEG`.
5. `GET_CLOCK`, then `UPDATE_CLOCK` (6-byte payload: local time + timezone offset).
6. `ENABLE_RAW_MODE`. Data starts arriving on channel 25.

## Stop sequence (`DeviceApiImpl::disconnect`)

- Raw mode: send `DISABLE_RAW_MODE`, then close all RFCOMM channels.
- Metrics mode: send `STOP_SESSION`, and optionally `GET_LAST_SESSION_ID` to
  delete the session stored on the headset. Then close the BLE connection.

## EEG data packet (63 bytes, 500 Hz)

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | sync `0xAA` |
| 1 | u8 | event id `0xEF` |
| 2 | u8 | data length `60` |
| 3 | u8 | HWCounter (wraps) |
| 4 | f32 LE | Ref |
| 8 | f32 LE | DRL |
| 12 + 4·i | f32 LE | Ch(i+1)RawEEG, i = 0..11, raw ADC counts |
| 60 | u8 | featureStatus |
| 61 | u16 LE | checksum = `sum(bytes[0..60]) & 0xFFFF` |

µV = raw × `0.023841858` (= 200000 / 2²³). Ref and DRL are **not** scaled.
Command sync byte (for replies sharing the stream) is `0xF6`.

## Signal quality (`ProtocolMW75::checkClipping` / `updateMinAndMaxValues` / `addSignalQualities`)

Evaluated over consecutive **1-second windows** (wall clock). The stats are
reset after each emit.

For each packet:

1. **Clipping, on raw values (before scaling):**
   - `refClip++` if `Ref <= 0 || Ref >= 4095`. `drlClip++` the same way for DRL.
   - `chClip[i]++` if `raw <= -8388608 || raw >= 8388607` (24-bit rails).
   - `total++`
2. Scale the channels to µV.
3. For each channel with a finite value, update the per-channel `min`/`max` (µV).
   Append finite `Ref` and `DRL` values to `refBuf` and `drlBuf`.

At the end of each window:

```
n = len(refBuf)
if n == 0 or n != len(drlBuf)                     -> everything "bad"
if refClip/n >= 0.25 or drlClip/n >= 0.25         -> everything "bad"
d = mean(|refBuf[k] - drlBuf[k]|)   (any non-finite -> everything "bad")
if d > 1000                                       -> everything "bad"
refQuality = drlQuality = d < 300 ? "best" : d < 600 ? "good" : "acceptable"

for each channel i in 1..12:
  if min/max not finite                           -> "bad"
  elif total > 0 and chClip[i]/total >= 0.25      -> "bad"
  else p2p = max - min  (µV)
       p2p <= 80  -> "best"
       p2p <= 180 -> "good"
       p2p <= 280 -> "acceptable"
       else       -> "bad"
```

Research Kit emits this to its UI once per second as JSON:
`{"refQuality": …, "drlQuality": …, "ch1Quality": …, …, "ch12Quality": …}`.
Values are one of `best | good | acceptable | bad`.

## Bluetooth link must stay active (verified on hardware, 2026)

Tested against MW75 Neuro `50:0B:91:A9:39:84`, firmware 2.0.0.74, via `tools/mw75_probe`:

- **Start/stop commands work.** `enable_raw_mode` (`FF 04 00 01 09 9A 03 41 01`) is
  acknowledged with `FF 03 00 01 09 9A 03 41 F1`, data begins ~1 s later, and
  `disable_raw_mode` (…`41 00`) stops it. The disable *reply* is often dropped, but the
  command still takes effect (data stops).
- **EEG only flows when the Classic link is kept active.** On an idle link, macOS lets
  the ACL connection drop into sniff mode and raw EEG arrives at only ~11 packets/s
  (~830 B/s, ~96 % loss). While audio is actively streaming to the headset, the same
  test delivers ~297 packets/s (~21 kB/s). The headset's own counter advances ~490–500/s
  throughout, so the loss is entirely in link-layer delivery to the host, not the headset.
- IOBluetooth exposes no sniff-mode control, so the practical fix is to keep audio
  playing through the headset while streaming (the experiment's audio stimuli do this; a
  near-silent keep-alive covers setup and signal-check before stimuli start).
- Even with audio active this crude probe still saw ~39 % loss; Research Kit hides
  residual loss with interpolation (on by default), which `Mw75StreamProcessor` also does.

## This driver's LSL stream (`packages/mw75_neuro`)

Same as Research Kit's (name from its config, type `EEG`, 16 × float32, nominal
500 Hz, `source_id` = Bluetooth address, channels `eeg1`–`eeg12` in µV, `ref`,
`drl`, `lslCumulativeCounter`), with three differences:

- **Channel 16 is `sampleStatus`** instead of Research Kit's `csvCumulativeCounter`
  (which is 0 outside Research Kit's own CSV recording): `0` measured, `1` lost over
  Bluetooth and linearly interpolated, `2` measured after more than 0.5 s without
  data. The 8-bit counter wraps every 256 samples, so the loss before a `2` may be
  undercounted. The codes are also written to the stream's `desc/sampleStatusCodes`.
- **Timestamps** follow the headset's measured rate (≈496.5 Hz on the lab unit, not
  500), anchored to the earliest packet arrivals, in `lsl_local_clock()` time
  (`CLOCK_MONOTONIC_RAW` on macOS). Research Kit stamps each sample at push time.
- **Optional filtering**: the app's plots apply Research Kit's 0.5 Hz first-order
  high-pass (its "DC offset" option) and a mains notch with its harmonic (Q 20) by
  default, plus an optional 2nd/4th-order Butterworth band-pass. The LSL stream
  carries them only if "Filter the LSL stream too" is switched on (off by default),
  and the settings at stream start are in `desc/filters`. The filters are causal. The
  notch centres itself on the measured line-noise peak, which on the lab headset sits
  at 0.1204 cycles/sample (59.7–59.8 Hz on the app's rate estimate), not exactly at
  60 Hz. The bench app's tests and their saved `eeg.csv` always use the unfiltered
  samples.

Measured loss on the lab headset: ~13% with no audio, ~44% while music plays
through the headset (A2DP shares the Bluetooth link).

## Metrics (Focus) session over BLE

Research Kit's "metrics" session runs over Bluetooth Low Energy instead of RFCOMM and
yields the headset's own Focus score and per-cup contact. Verified on the lab headset
(firmware 2.0.0.74) with `packages/mw75_neuro` (`Mw75MetricSession`).

- **GATT:** service `00001100-D102-11E1-9B23-00025B00A5A5`; commands are written (with
  response) to `…1101-…A5A5`; subscribe `…1102-…A5A5` (replies and events) and
  `00001105-D102-11E1-9B23-00025B00A5A6`. BLE commands have no GAIA `FF 04 00 <len>`
  header; replies are `09 9A 03 <op> <status> …` with `F1` = success, `F0` = refused.
- **Start:** `get_clock` (`09 9A 03 32`, always answered `F0` here, ignored),
  `update_clock` (`09 9A 03 31` + u32 LE Unix seconds + i16 LE UTC offset minutes),
  `set_calibration` (`09 9A 03 7C E1 B6 27 3E 20 3D D1 3E 14 00 1E 00 0A 00`),
  `start_session` (`09 9A 03 35 04` → `35 F1 <session id:2> 04`).
- **Stop:** `stop_session` (`09 9A 03 36 FF` → `36 F1 00`). Research Kit then reads the
  last session ID (`09 9A 03 3C 00`) and deletes it (`09 9A 03 3E <id>`); this driver
  deliberately does not delete anything, so session records accumulate on the headset.
- **Focus:** chunks `09 9A 03 84 AA FC <len> <index u16 LE> <payload>` make a 128-byte
  record; the f32 LE at byte 120 is Focus (0–1), about once a second. The first ~25 s
  after start were all 0.
- **Per-cup contact:** `09 9A 03 E1 <left> <right>`, 0–5, about once a second during a
  metrics session. In raw mode the headset sends it only when the command channel
  opens (and once when raw mode ends), never while raw EEG streams.
- **Pause/resume:** when the headset is lifted off the head it pauses the session by
  itself — `82 02 <id> <pause time u32 LE> …`, `F4 02`, `E2 01`, `3B F1 00` — and sends no
  scores; back on the head it resumes — `82 01 <id> …`, `F4 00`, `E2 00`, `3A F1 00`.
  (`82` = session status; `E2` looks like the wear sensor.)
- **Not with raw EEG:** while raw mode is on, the headset answers the metrics commands
  `F0` and holds `start_session`, starting the session only once raw mode is switched
  off. Run one or the other. If a start attempt fails after `start_session` was sent,
  send `stop_session`, or the headset keeps a session running and refuses the next start.
