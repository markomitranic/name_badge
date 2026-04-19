#!/bin/sh
# Run the local simulator (LiveView preview at http://localhost:4000).
# Pair with ./scripts/clean.sh first when switching away from a trellis build.

set -e
set -x

export MIX_TARGET=host

mix deps.get
iex -S mix
