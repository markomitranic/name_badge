#!/bin/sh
# Start (or relabel) an on-device battery logger for power-draw experiments.
# Samples NameBadge.Battery.voltage() every 15 s and appends
# "<iso8601>,<label>,<voltage>" to /data/power.log ON THE BADGE, so logging
# survives SSH disconnects and WiFi being hard-powered off mid-experiment.
#
# Usage:
#   ./scripts/power_mark.sh baseline_menu     # start logging, label the leg
#   ./scripts/power_mark.sh spotify_wifi_off  # relabel at each leg transition
#   ./scripts/power_mark.sh --stop            # kill the logger
#   sftp nerves@wisteria.local:/data/power.log .   # pull results afterwards
#
# Experiment protocol (see power.log analysis, 2026-07-16):
#   - Charge to ~4.0 V, flash current firmware, UNPLUG USB (while plugged in,
#     WiFi never powers down by design, and charging masks the drain).
#   - Run A/B/A/B/A legs of ~70 min each (2 ArtCache refill cycles):
#       A = top-level menu, WiFi on, idle.  B = Spotify screen, WiFi off.
#   - Relabel via this script at every transition (needs WiFi up: do it from
#     the menu screen, right before entering/after leaving Spotify).
#   - Discard the first 5 min of every leg (Li-ion relaxation transient).
#   - Stay inside the 3.7-4.0 V band; abort below 3.5 V (no low-battery
#     cutoff exists in this firmware). Compare the SET of A slopes to the
#     SET of B slopes, in mV/h — a single A/B pair proved misleading before.
# Password: nerves.

set -e

HOST="${2:-wisteria.local}"

if [ "$1" = "--stop" ]; then
  ssh "nerves@$HOST" '
  case Process.whereis(:power_exp) do
    nil -> IO.puts("no logger running")
    pid -> Process.exit(pid, :kill); IO.puts("logger stopped")
  end
  '
  exit 0
fi

LABEL="${1:?usage: power_mark.sh <label> [host] | --stop}"

ssh "nerves@$HOST" '
defmodule PowerLog do
  def start(label) do
    case Process.whereis(:power_exp) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    Process.sleep(100)
    pid = spawn(fn -> loop(label) end)
    Process.register(pid, :power_exp)
    IO.puts("logging to /data/power.log as " <> label)
  end

  defp loop(label) do
    v = NameBadge.Battery.voltage()
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    v_str = :io_lib.format("~.4f", [v]) |> IO.iodata_to_binary()
    File.write!("/data/power.log", "#{ts},#{label},#{v_str}\n", [:append])
    Process.sleep(15_000)
    loop(label)
  end
end

PowerLog.start("'"$LABEL"'")
'
