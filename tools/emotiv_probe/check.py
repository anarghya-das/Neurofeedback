# /// script
# requires-python = ">=3.10"
# dependencies = ["hidapi", "pycryptodome"]
# ///
"""Check that an Emotiv EPOC+ can be read through its USB dongle, without Emotiv software.

Read-only: it only listens to the dongle's HID input reports and never writes to the
dongle or the headset. See docs/emotiv-epoc-plus.md for the packet format.

    uv run tools/emotiv_probe/check.py              # 10 s check
    uv run tools/emotiv_probe/check.py --seconds 30
"""

import argparse
import statistics as st
import sys
import time

import hid
from Crypto.Cipher import AES

VENDOR_ID, PRODUCT_ID = 0x1234, 0xED02
EEG_USAGE = 2  # the dongle's second HID interface (usage page 0xFFFF) carries the data
EEG_PACKET, MOTION_PACKET = 16, 32  # byte 1 of a decrypted report

# Slot order as CyKit labels it. Not yet verified on this headset (see the doc).
CHANNELS = ["AF3", "F7", "F3", "FC5", "T7", "P7", "O1", "O2", "P8", "T8", "FC6", "F4", "F8", "AF4"]
CHANNEL_BYTES = list(range(2, 16, 2)) + list(range(18, 32, 2))


def keys(serial: str) -> dict[str, bytes]:
    """AES-128 keys derived from the dongle serial, as CyKit and emotiv-lsl build them.
    The first is the one confirmed on the lab's EPOC+; the rest are fallbacks for other units."""
    s = [ord(c) for c in serial]
    a, b, c, d = s[-1], s[-2], s[-3], s[-4]
    return {
        "EPOC+ 16-bit (CyKit model 6)": bytes([a, b, b, c, c, c, b, d, a, d, b, b, d, d, b, a]),
        "EPOC+ premium (CyKit model 5)": bytes([b, a, b, a, c, d, c, d, d, c, d, c, a, b, a, b]),
        "EPOC+ 14-bit (CyKit model 7)": bytes([a, 0, b, 21, c, 0, d, 12, c, 0, b, 68, a, 0, b, 88]),
        "EPOC X (emotiv-lsl)": bytes([a, b, d, d, b, a, b, d, a, d, c, b, a, b, b, c]),
    }


def microvolts(lo: int, hi: int) -> float:
    """CyKit's EPOC+ 16-bit conversion. Values sit on a ~4200 µV offset."""
    return lo * 0.128205128205129 + 4201.02564096001 + (hi - 128) * 32.82051289


def decode_score(packets: list[bytes], key: bytes) -> tuple[float, list[bytes]]:
    """Fraction of EEG packets whose counter steps by exactly one, and the decrypted packets."""
    cipher = AES.new(key, AES.MODE_ECB)
    dec = [cipher.decrypt(p) for p in packets if len(p) == 32]
    eeg = [d for d in dec if d[1] == EEG_PACKET]
    steps = [(y[0] - x[0]) % 256 for x, y in zip(eeg, eeg[1:])]
    if len(eeg) < 10 or sum(d[1] in (EEG_PACKET, MOTION_PACKET) for d in dec) < 0.9 * len(dec):
        return 0.0, dec
    # The counter wraps at 128 (or 256 in 256 Hz mode); count the wrap as a step of one.
    ok = sum(s == 1 or (x[0] in (127, 255) and y[0] == 0) for s, x, y in zip(steps, eeg, eeg[1:]))
    return ok / len(steps), dec


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=float, default=10, help="how long to listen (default 10)")
    args = parser.parse_args()

    interfaces = hid.enumerate(VENDOR_ID, PRODUCT_ID)
    info = next((d for d in interfaces if d["usage"] == EEG_USAGE), None)
    if info is None:
        print("No Emotiv dongle found (USB 1234:ED02).")
        print("Plug it in directly or through a powered adapter, then run this again.")
        return 1
    serial = info["serial_number"] or ""
    print(f"Dongle found: {info['product_string']!r}, serial {serial[:6]}…, {len(interfaces)} HID interfaces")

    device = hid.device()
    device.open_path(info["path"])
    packets, t0 = [], time.time()
    try:
        while time.time() - t0 < args.seconds:
            report = device.read(32, timeout_ms=500)
            if report:
                packets.append(bytes(report))
    finally:
        device.close()
    elapsed = time.time() - t0

    if not packets:
        print(f"The dongle sent nothing in {elapsed:.0f} s: the headset is off, out of range or not linked.")
        return 2
    print(f"Received {len(packets)} reports in {elapsed:.1f} s")

    scores = {name: decode_score(packets, key) for name, key in keys(serial).items()}
    name, (score, dec) = max(scores.items(), key=lambda kv: kv[1][0])
    if score < 0.9:
        print("No known key decodes this headset's data:")
        for n, (s, _) in scores.items():
            print(f"  {n:32s} counter steps by one in {s:.0%} of packets")
        return 3
    print(f"Decrypted with key: {name}")

    eeg = [d for d in dec if d[1] == EEG_PACKET]
    motion = [d for d in dec if d[1] == MOTION_PACKET]
    other = len(dec) - len(eeg) - len(motion)
    wrap = max(d[0] for d in eeg) + 1
    lost = sum((y[0] - x[0]) % wrap - 1 for x, y in zip(eeg, eeg[1:]))
    print(f"EEG:    {len(eeg) / elapsed:6.1f} Hz (counter wraps at {wrap}), "
          f"{lost} of {len(eeg) + lost} samples dropped ({lost / (len(eeg) + lost):.2%})")
    print(f"Motion: {len(motion) / elapsed:6.1f} Hz | undecodable reports: {other}")
    battery = sorted({d[16] for d in eeg if d[16]})
    print(f"Byte 16 non-zero values (battery/status?): {battery or 'none'}")

    print("\nslot  mean µV   sd µV   min..max µV   (labels per CyKit, unverified)")
    for label, i in zip(CHANNELS, CHANNEL_BYTES):
        v = [microvolts(d[i], d[i + 1]) for d in eeg]
        print(f"{label:4s} {st.mean(v):8.1f} {st.pstdev(v):7.1f}   {min(v):7.1f}..{max(v):7.1f}")
    print("\nOn a head with damp pads each channel should vary by tens of µV; 2–5 µV means no skin contact.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
