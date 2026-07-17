# Deeper analysis of a pulled /data/cpu_test.csv from the CPU-core A/B test.
#
# Usage:
#   sftp nerves@wisteria.local:/data/cpu_test.csv .
#   elixir scripts/analyze_cpu_test.exs cpu_test.csv
#
# Prints per-leg drain slopes (both the EMA'd and burst-averaged raw voltage),
# residual noise, the curvature-compensated verdict, and how busy each core
# actually was per leg (from /proc/stat idle ticks).

defmodule Analyze do
  @discard_s 180

  def main([path]) do
    rows =
      path
      |> File.stream!()
      |> Stream.drop(1)
      |> Enum.map(&parse_row/1)
      |> Enum.reject(&is_nil/1)

    legs = Enum.group_by(rows, & &1.phase)

    IO.puts("== Per-leg slopes (first #{@discard_s}s discarded) ==")

    slopes =
      for phase <- ~w(a1 b a2), rows = legs[phase] do
        used = Enum.filter(rows, &(&1.elapsed >= @discard_s))
        {s_ema, _} = fit(used, & &1.ema)
        {s_raw, sigma} = fit(used, & &1.raw)
        busy = busy_pct(rows)

        IO.puts(
          "#{String.pad_trailing(phase, 3)} ema #{fmt(s_ema)} mV/h | raw #{fmt(s_raw)} mV/h " <>
            "| residual sigma #{fmt(sigma)} mV | cpu busy #{busy}"
        )

        {phase, s_raw}
      end

    slopes = Map.new(slopes)

    if map_size(slopes) == 3 do
      a_interp = (slopes["a1"] + slopes["a2"]) / 2
      delta = slopes["b"] - a_interp

      IO.puts("")
      IO.puts("== Verdict (raw voltage) ==")
      IO.puts("A interpolated at B midpoint: #{fmt(a_interp)} mV/h")
      IO.puts("Delta (B - A): #{fmt(delta)} mV/h (#{fmt(delta / abs(a_interp) * 100)}%)")
      IO.puts("Positive = single-core drains slower = savings.")
    else
      IO.puts("\nIncomplete run: only #{inspect(Map.keys(slopes))} legs present.")
    end
  end

  defp parse_row(line) do
    case String.split(String.trim(line), ",") do
      [_ts, phase, elapsed, ema, raw, load1, temp, idle0, idle1] ->
        %{
          phase: phase,
          elapsed: String.to_float(elapsed),
          ema: String.to_float(ema),
          raw: String.to_float(raw),
          load1: load1,
          temp: temp,
          idle0: int_or_nil(idle0),
          idle1: int_or_nil(idle1)
        }

      _ ->
        nil
    end
  end

  defp int_or_nil("-"), do: nil
  defp int_or_nil(s), do: String.to_integer(s)

  defp fit(rows, getter) do
    n = length(rows)
    t_mean = Enum.sum(Enum.map(rows, & &1.elapsed)) / n
    v_mean = Enum.sum(Enum.map(rows, getter)) / n

    num = Enum.reduce(rows, 0.0, fn r, acc -> acc + (r.elapsed - t_mean) * (getter.(r) - v_mean) end)
    den = Enum.reduce(rows, 0.0, fn r, acc -> acc + (r.elapsed - t_mean) * (r.elapsed - t_mean) end)
    slope = num / den

    sse =
      Enum.reduce(rows, 0.0, fn r, acc ->
        resid = getter.(r) - v_mean - slope * (r.elapsed - t_mean)
        acc + resid * resid
      end)

    {slope * 3600, :math.sqrt(sse / max(n - 2, 1))}
  end

  # Fraction of jiffies each core spent non-idle across the leg. 100 Hz jiffies,
  # so ticks between first and last sample vs wall time give utilization.
  defp busy_pct(rows) do
    first = List.first(rows)
    last = List.last(rows)
    wall_ticks = (last.elapsed - first.elapsed) * 100

    for {core, get} <- [{"cpu0", & &1.idle0}, {"cpu1", & &1.idle1}] do
      case {get.(first), get.(last)} do
        {a, b} when is_integer(a) and is_integer(b) and wall_ticks > 0 ->
          "#{core} #{fmt((1 - (b - a) / wall_ticks) * 100)}%"

        _ ->
          "#{core} n/a"
      end
    end
    |> Enum.join(" ")
  end

  defp fmt(f), do: :erlang.float_to_binary(f / 1, decimals: 1)
end

Analyze.main(System.argv())
