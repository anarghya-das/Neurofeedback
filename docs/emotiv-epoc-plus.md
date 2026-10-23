# Emotiv EPOC+: raw EEG through the USB dongle, without Emotiv software

Emotiv's own software (EMOTIV Launcher, EmotivPRO, the Cortex API) only gives raw
EEG with a paid license. This route needs no Emotiv software or license: the app
reads the dongle as a USB HID device and decrypts the packets itself, using the
key scheme and µV conversion from [CyKit](https://github.com/CymatiCorp/CyKit).
The decryption is reverse-engineered, not an official Emotiv interface.

**Verified on 2026-10-23** on the lab Mac (Apple Silicon, macOS 27) with the lab's
headset, off the head: the dongle opens with no permission prompt, every packet
decrypts, and a 10 s capture had 0 dropped samples at 128 Hz. **Not yet verified:**
which slot is which electrode, whether contact quality is in the stream, what the
"battery" byte means, and which motion values are which sensor. Those need the
headset worn with damp pads (see the plan in
[multi-device-plan.md](multi-device-plan.md)).

## Connect and check

1. **Charge the headset.** A full charge lasts about 12 hours.
2. **Wet the felt pads** with saline solution until damp but not dripping, and
   screw them into the arms. Dry pads read as flat signal.
3. **Plug in the USB dongle.** It is USB-A, so use a USB-C adapter. If macOS asks
   "Allow accessory to connect?", click Allow. The dongle came paired with this
   headset, so there is no pairing step.
4. **Switch the headset on** with the switch on the back; its light comes on.
5. **Run the check** from the repo root:

   ```sh
   uv run tools/emotiv_probe/check.py            # listens for 10 s
   uv run tools/emotiv_probe/check.py --seconds 30
   ```

   It only listens; it never writes to the dongle or the headset.

| Check says | Meaning |
|---|---|
| `No Emotiv dongle found (USB 1234:ED02)` | macOS does not see the dongle. Re-plug it; `system_profiler SPUSBDataType` should list "Brain Computer Interface USB Receiver/Dongle". |
| `The dongle sent nothing` | The dongle is fine but the headset is off, out of range or flat. Switch it off and on; if still silent, re-plug the dongle, then switch the headset off and on again. |
| `No known key decodes this headset's data` | A different model or firmware. The check tries CyKit's other EPOC+ keys and the EPOC X key; none matched. |
| `Decrypted with key: …` and per-channel stats | Working. Off the head each channel varies by only 2–5 µV; worn with damp pads it should vary by tens of µV. |

6. **Once worn (still to do):** blink and look for large spikes at AF3/AF4, then
   close your eyes for 10 s and look for 8–12 Hz alpha at O1/O2. This confirms
   the channel order below.

**Do not change the headset's settings.** Its 2023 EmotivPRO logs show 256 Hz, but
it now runs at 128 Hz. Changing the rate without Emotiv software means CyKit on
Windows over the USB cable, which has only been tested on firmware 0x565 and
0x625. This headset has 0x634.

## Device

| | |
|---|---|
| Headset | `EPOCPLUS-4A2C110A`, firmware 0x0634 |
| Dongle | USB VID `0x1234`, PID `0xED02`, product "Brain Computer Interface USB Receiver/Dongle", serial `UD2016…` |
| HID interfaces | Two. Data arrives on the one with usage page `0xFFFF`, usage `2`. The other (usage page `0xF0FF`) is not used. |
| Access on macOS | Through the HID API (`hidapi` in Python, `IOHIDManager` natively). libusb-based tools (CyKit's pyusb path) cannot claim the dongle on macOS. |
| Rates now | EEG 128 Hz, motion 64 Hz |

## Packet format

Each HID input report is 32 bytes, encrypted with AES-128 in ECB mode (two
16-byte blocks, same key). No XOR step before decrypting; the EPOC X needs
`^ 0x55` on every byte, the EPOC+ does not.

**Key.** Built from the dongle's serial number. With `a`, `b`, `c`, `d` the ASCII
codes of the serial's last, second-to-last, third-to-last and fourth-to-last
characters, the key is the 16 bytes
`a b b c c c b d a d b b d d b a` (CyKit's key model 6, "EPOC+ 16-bit").

**Decrypted report.** Byte 0 is a counter, byte 1 the packet type: `16` EEG,
`32` motion.

EEG packet (type 16):

| Bytes | Content |
|---|---|
| 0 | Sample counter, 0–127 at 128 Hz |
| 2–15, 18–31 | 14 channels as `(lo, hi)` byte pairs |
| 16 | Usually 0; 47 once per second at counter 127. Battery or status, unconfirmed. |
| 17 | Always 0 so far |

µV per channel: `lo × 0.128205128205129 + 4201.02564096001 + (hi − 128) × 32.82051289`.
Values sit on an offset of about 4200 µV, so high-pass or subtract the mean
before use.

Slot order as CyKit labels it, **unverified for this headset** (emotiv-lsl had to
swap several pairs for the EPOC X): AF3, F7, F3, FC5, T7, P7, O1, O2, P8, T8,
FC6, F4, F8, AF4.

Motion packet (type 32): own counter 0–63 at 64 Hz, nine little-endian `int16` at
bytes 2–19, bytes 20–31 zero. Inferred from the headset lying still: bytes 2–7
gyroscope (small, noisy), 8–13 accelerometer (vector length ≈ 16 400, about 1 g at
16 384 per g), 14–19 magnetometer. Moving the headset would confirm this.

**Contact quality is not in the stream as far as we know.** Emotiv's software shows
a per-electrode quality map, but the two bytes CyKit calls "battery/quality" were
almost always 0 in captures taken off the head. Re-check while worn; if it is
still absent, the app computes quality from the EEG itself (flat signal, railing,
drift, mains hum, dropped packets).

## What else was tried

| Option | Why not |
|---|---|
| BrainFlow | No Emotiv board among its supported devices, and no generic HID input. Its filtering and band-power functions work on any array. |
| CyKit | Has the right key and conversion, but its USB layer is Windows-only. |
| vtr0n/emotiv-lsl | EPOC X only, but its `hidapi` structure is what the check script follows. |
| emokit, hemokit | EPOC+ made before 2016 only, or no macOS. emokit is archived. |
| xavier-tools, brain-drain | Original EPOC (128 Hz, 14-bit) only. |
| CrossOver + CyKit | Wine only passes gamepads and joysticks through, so CyKit never sees the dongle. |

Sources: [CyKit](https://github.com/CymatiCorp/CyKit),
[vtr0n/emotiv-lsl](https://github.com/vtr0n/emotiv-lsl),
[EmotivPRO raw EEG docs](https://emotiv.gitbook.io/emotivpro-v3/data-streams/raw-eeg),
[BrainFlow supported boards](https://brainflow.readthedocs.io/en/stable/SupportedBoards.html).
