Read LSL streams and inspect packet structure

This folder contains a small Python helper to read Lab Streaming Layer (LSL) streams and print the packet/data structure.

Setup

1. Create a Python virtual environment (recommended):

   python3 -m venv .venv
   source .venv/bin/activate

2. Install dependencies:

   pip install -r tools/requirements.txt

Usage

- List streams:

   python tools/read_lsl_stream.py --list

- Read 5 samples from a stream named "EEG":

   python tools/read_lsl_stream.py --name EEG --count 5

- Read samples from the first discovered stream:

   python tools/read_lsl_stream.py --index 0 --count 10

- Use chunk mode:

   python tools/read_lsl_stream.py --name EEG --chunk --count 3

Notes

- The script requires an LSL publisher to be running and visible on the network/local host.
- If `pylsl` is not installed, install it with `pip install pylsl`.
