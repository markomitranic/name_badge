#!/bin/sh
# Build trellis firmware (_build/trellis_dev/nerves/images/name_badge.fw).

set -e

# `mix` on PATH is a mise shim: it re-applies mise's own config env over
# whatever the caller exported, so a stray MIX_TARGET in a mise config wins
# over an `export`. Going through `mise exec` puts the real mix binary on
# PATH, where `env` can set the target for real.
MIX="mise exec -- env MIX_TARGET=trellis mix"

set -x

$MIX deps.get
$MIX firmware
