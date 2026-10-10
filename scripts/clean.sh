#!/bin/sh
# Nuke build artifacts and fetched deps. Use when a build gets into a bad
# state (symptom: "Unexpected executable format" on firmware build).
# After this, run ./scripts/build.sh to refetch deps.

set -e
set -x

rm -rf _build deps
