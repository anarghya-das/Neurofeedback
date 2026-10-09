#!/bin/sh
# Builds the MW75 hardware probe. The Info.plist is embedded so macOS shows the
# Bluetooth permission prompt instead of killing the process.
set -e
cd "$(dirname "$0")"
xcrun swiftc -O mw75_probe.swift -o mw75_probe \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
echo "built $(pwd)/mw75_probe"
