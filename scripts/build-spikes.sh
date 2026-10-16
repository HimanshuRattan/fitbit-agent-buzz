#!/bin/zsh
# Compiles the CoreBluetooth experiment tools in spike/ (scan, gatt, watch, direct, find-air).
# Each embeds spike/Info.plist so macOS allows Bluetooth access.
set -eu
SPIKE="${0:A:h:h}/spike"
for tool in scan gatt watch direct find-air; do
  swiftc -O "$SPIKE/$tool.swift" -o "$SPIKE/$tool" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$SPIKE/Info.plist"
  echo "Built spike/$tool"
done
