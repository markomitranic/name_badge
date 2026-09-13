#!/bin/sh
# Run the local simulator (LiveView preview at http://localhost:4000).
# Pair with ./scripts/clean.sh first when switching away from a trellis build.

set -e

# `mix` on PATH is a mise shim: it re-applies mise's own config env over
# whatever the caller exported, so an `export MIX_TARGET` here would be
# silently ignored. Going through `mise exec` puts the real mix binary on
# PATH, where `env` can set the target for real.
set -x

mise exec -- env MIX_TARGET=host mix deps.get
mise exec -- env MIX_TARGET=host iex -S mix
