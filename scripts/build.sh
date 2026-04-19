#!/bin/sh
# Build trellis firmware (_build/trellis_dev/nerves/images/name_badge.fw).
# Pair with ./scripts/clean.sh first when switching away from a host build.

set -e
set -x

export MIX_TARGET=trellis

mix deps.get
mix firmware
