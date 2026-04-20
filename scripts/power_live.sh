#!/bin/sh
# Stream live battery/CPU metrics from the badge. Prints to terminal AND
# appends to ./power.log on this laptop. Ctrl+C to stop. Password: nerves.

set -e

ssh nerves@wisteria.local '
defmodule PL do
  def loop(prev) do
    v = NameBadge.Battery.voltage()
    pct = NameBadge.Battery.percentage()
    chg = if NameBadge.Battery.charging?(), do: "CHG", else: "BAT"

    ["cpu" | raw] =
      File.read!("/proc/stat") |> String.split("\n") |> hd()
      |> String.split(~r/\s+/, trim: true)
    ints = Enum.map(raw, &String.to_integer/1)
    [_u, _n, _s, idle | _] = ints
    total = Enum.sum(ints)
    busy = total - idle
    cpu =
      case prev do
        %{busy: pb, total: pt} when total > pt ->
          trunc((busy - pb) * 100 / (total - pt))
        _ -> nil
      end

    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    v_str = :io_lib.format("~.4f", [v]) |> IO.iodata_to_binary()
    cpu_str = if cpu, do: Integer.to_string(cpu), else: ""
    IO.puts("#{ts},#{chg},#{v_str},#{pct},#{cpu_str}")

    Process.sleep(1000)
    loop(%{busy: busy, total: total})
  end
end
IO.puts("ts,state,voltage_v,soc_pct,cpu_pct")
PL.loop(nil)
' | tee -a power.log
