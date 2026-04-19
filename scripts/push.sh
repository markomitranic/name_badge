#!/bin/sh
# OTA-style flash: pipe the most recent firmware image to a booted badge over SSH.
# Default host: wisteria.local. Override with: ./scripts/push.sh other.local
# Assumes ./scripts/build.sh has been run. SSH password is `nerves`.

set -e
set -x

HOST="${1:-wisteria.local}"
FW="_build/trellis_dev/nerves/images/name_badge.fw"

if [ ! -f "$FW" ]; then
  echo "Firmware not found at $FW — run ./scripts/build.sh first." >&2
  exit 1
fi

cat "$FW" | ssh -s "nerves@$HOST" fwup
