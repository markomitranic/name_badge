#!/bin/sh
# Nuke build artifacts and fetched deps. Run this when switching MIX_TARGET
# between `host` (simulator) and `trellis` (device) — mixed-target builds
# corrupt native NIFs (symptom: "Unexpected executable format" on firmware build).
# After this, run ./scripts/dev.sh or ./scripts/build.sh to refetch deps.

set -e
set -x

rm -rf _build deps
