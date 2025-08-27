#!/usr/bin/env python3
"""
Simple LSL EEG data generator for testing the Flutter EEG viewer.
This script generates synthetic EEG-like data with multiple channels.

Requirements:
    pip install pylsl numpy

Usage:
    python lsl_eeg_generator.py
"""

import time
import numpy as np
from pylsl import StreamInfo, StreamOutlet
import math
import random


def main():
    print("Creating LSL stream for EEG data...")

    # Create stream info
    n_channels = 8
    sampling_rate = 250  # Hz
    stream_name = "TestEEG"
    stream_type = "EEG"

    info = StreamInfo(
        name=stream_name,
        type=stream_type,
        channel_count=n_channels,
        nominal_srate=sampling_rate,
        channel_format='float32',
        source_id='test_eeg_001'
    )

    # Optionally add channel information
    channels = info.desc().append_child("channels")
    for i in range(n_channels):
        ch = channels.append_child("channel")
        ch.append_child_value("label", f"Ch{i+1}")
        ch.append_child_value("unit", "microvolts")
        ch.append_child_value("type", "EEG")

    # Create outlet
    outlet = StreamOutlet(info)
    print(f"Created LSL outlet: {stream_name} ({stream_type})")
    print(f"Channels: {n_channels}, Sampling rate: {sampling_rate} Hz")
    print("Starting data transmission... (Press Ctrl+C to stop)")

    # Generate and send data
    start_time = time.time()
    sample_count = 0

    try:
        while True:
            # Generate synthetic EEG-like data
            current_time = time.time() - start_time
            sample = []

            for ch in range(n_channels):
                # Create synthetic EEG signal with multiple frequency components
                # Base frequency components (alpha, beta, theta)
                alpha_wave = 10 * \
                    math.sin(2 * math.pi * 10 * current_time)  # 10 Hz alpha
                # 20 Hz beta
                beta_wave = 5 * math.sin(2 * math.pi * 20 * current_time)
                theta_wave = 15 * \
                    math.sin(2 * math.pi * 6 * current_time)   # 6 Hz theta

                # Add some channel-specific phase and amplitude variations
                phase_offset = ch * math.pi / 4
                amplitude_factor = 0.8 + 0.4 * math.sin(ch * math.pi / 8)

                # Combine waves with noise
                signal = amplitude_factor * (
                    alpha_wave * math.cos(phase_offset) +
                    beta_wave * math.sin(phase_offset) +
                    theta_wave * math.cos(phase_offset * 2)
                )

                # Add some noise
                noise = random.gauss(0, 2)

                # Add occasional "artifacts" or spikes
                if random.random() < 0.001:  # 0.1% chance
                    signal += random.gauss(0, 50)

                sample.append(signal + noise)

            # Send the sample
            outlet.push_sample(sample)

            sample_count += 1
            if sample_count % 1000 == 0:
                print(f"Sent {sample_count} samples ({current_time:.1f}s)")

            # Wait for next sample
            time.sleep(1.0 / sampling_rate)

    except KeyboardInterrupt:
        print(
            f"\nStopping data transmission. Sent {sample_count} samples total.")


if __name__ == "__main__":
    main()
