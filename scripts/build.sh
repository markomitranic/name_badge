#!/bin/sh
# Build trellis firmware (_build/trellis_dev/nerves/images/name_badge.fw).
# Pair with ./scripts/clean.sh first when switching away from a host build.

set -e

# `mix` on PATH is a mise shim: it re-applies mise's own config env over
# whatever the caller exported, and .mise.local.toml pins MIX_TARGET=host for
# the simulator. So `export MIX_TARGET=trellis` here is silently ignored and
# you get a host build. Going through `mise exec` puts the real mix binary on
# PATH, where `env` can set the target for real.
MIX="mise exec -- env MIX_TARGET=trellis mix"

set -x

$MIX deps.get
$MIX firmware
