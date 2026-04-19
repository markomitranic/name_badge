#!/bin/sh
# SSH into the badge for an IEx prompt.
# Default host: wisteria.local. Override with: ./scripts/ssh.sh other.local
# Password: nerves

set -e
set -x

HOST="${1:-wisteria.local}"

ssh "nerves@$HOST"
