#!/bin/sh
# FEL-mode flash over USB-C: first-time install or brick recovery.
# Only needed when the badge can't boot / can't be reached over SSH.
# Full procedure: docs/usb_fel_loaders.md

set -e

cat <<'EOF'
==================================================================
  Badge flash over USB-FEL (first-time install / brick recovery)
==================================================================

Before continuing, complete these steps:

  1. Power the badge OFF.
  2. Hold the FEL button on the badge.
  3. Plug it into USB-C (keep the FEL button held).
  4. Release the FEL button once connected.

  5. In a SEPARATE terminal, from a clone of usb_fel_loaders:
       git clone https://github.com/gworkman/usb_fel_loaders
       cd usb_fel_loaders
       ./launch.sh trellis
     Wait until the badge shows up as a USB mass-storage device.

  6. Return here once launch.sh is running and the badge is visible.

If "usb_bulk_send() ERROR -1" appears: wait a few seconds in FEL, swap
to a known-good USB-C DATA cable, or `brew reinstall libusb`.

==================================================================

Press Enter to continue, or Ctrl-C to abort.
EOF

read -r _

set -x

export MIX_TARGET=trellis

mix deps.get
mix firmware
mix burn
