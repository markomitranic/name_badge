defmodule NameBadge.PowerTest do
  @moduledoc """
  One-shot A/B battery-drain experiment: does taking CPU1 offline reduce idle draw?

  Armed at boot (test firmware only). Waits for USB unplug, hard-powers WiFi off
  and quiesces NervesHub/NTP, then runs three legs — A (both cores, 2 schedulers),
  B (CPU1 offline, 1 scheduler), A again — of 18 minutes each, sampling battery
  voltage every 5 s into /data/cpu_test.csv. The bracketing A legs compensate the
  battery discharge curve: B's slope is compared against the mean of A1 and A2,
  which is exact for any quadratic curvature. The first 3 minutes of every leg
  are logged but excluded from the fit (Li-ion relaxation transient).

  Ends by restoring cores, schedulers, WiFi and NTP, then paints the verdict on
  the e-ink. Runs once per flash: `rm /data/cpu_test_state` and reboot to re-arm.
  Plugging USB in mid-run aborts safely and restores everything.

  CSV columns: iso_ts, phase, leg_elapsed_s, mv_ema, mv_raw25, load1, temp_mc,
  idle_ticks_cpu0, idle_ticks_cpu1.
  """

  require Logger

  @state_file "/data/cpu_test_state"
  @csv "/data/cpu_test.csv"
  @result "/data/cpu_test_result.txt"

  @legs [:a1, :b, :a2]
  @leg_ms :timer.minutes(18)
  @settle_ms :timer.minutes(3)
  @sample_ms :timer.seconds(5)
  @discard_s 180
  @adc_path "/sys/bus/iio/devices/iio:device0/in_voltage0_raw"

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [__MODULE__, :run, []]},
      restart: :temporary
    }
  end

  @doc """
  Entry point, started as a supervised Task at boot.

  Shows the armed screen and blocks until USB power disappears, then runs the
  experiment. If a previous run left a state file behind, only reports it.

  @example `NameBadge.PowerTest.run() // :ok`
  """
  def run do
    case File.read(@state_file) do
      {:ok, state} ->
        screen("""
        = CPU test already ran
        State: #{String.trim(state)}

        Data: #raw("/data/cpu_test.csv")
        Verdict: #raw("/data/cpu_test_result.txt")

        To re-arm: #raw("rm /data/cpu_test_state") and reboot.
        """)

      {:error, _} ->
        screen("""
        = CPU core A/B test armed
        Unplug USB to start.

        3 min settle, then legs of 18 min: A (2 cores), B (1 core), A again. WiFi is off for the whole run, total 57 min.

        The screen will announce the verdict. Plugging USB back in aborts.
        """)

        wait_for_unplug()
        File.write!(@state_file, "running")
        execute()
    end

    :ok
  end

  defp execute do
    outcome =
      try do
        quiesce()
        Process.sleep(@settle_ms)

        slopes =
          for phase <- @legs do
            set_cores(phase)
            {phase, slope_mv_h(sample_leg(phase))}
          end

        {:ok, slopes}
      catch
        :throw, :usb_plugged -> :aborted
        kind, error -> {:error, {kind, error}}
      after
        restore()
      end

    case outcome do
      {:ok, slopes} ->
        File.write!(@state_file, "done")
        report(slopes)

      :aborted ->
        File.write!(@state_file, "aborted")

        screen("""
        = TEST ABORTED
        USB power detected mid-run.

        Cores, schedulers and WiFi are restored. Partial data in #raw("/data/cpu_test.csv").
        """)

      {:error, {kind, error}} ->
        File.write!(@state_file, "crashed")
        Logger.error("PowerTest crashed: #{inspect(kind)} #{inspect(error)}")

        screen("""
        = TEST CRASHED
        #raw("#{inspect(error, limit: 5)}")

        Cores, schedulers and WiFi are restored. See #raw("/data/debug.log").
        """)
    end
  end

  defp wait_for_unplug(streak \\ 0)
  defp wait_for_unplug(3), do: :ok

  defp wait_for_unplug(streak) do
    Process.sleep(@sample_ms)
    if NameBadge.Battery.charging?(), do: wait_for_unplug(0), else: wait_for_unplug(streak + 1)
  end

  defp quiesce do
    _ = Application.stop(:nerves_hub_link)
    _ = Application.stop(:nerves_time)
    NameBadge.Network.wifi_off()
    File.write!(@csv, "iso_ts,phase,elapsed_s,mv_ema,mv_raw25,load1,temp_mc,idle0,idle1\n")
  end

  defp restore do
    _ = File.write("/sys/devices/system/cpu/cpu1/online", "1")
    _ = :erlang.system_flag(:schedulers_online, :erlang.system_info(:schedulers))
    _ = Application.ensure_all_started(:nerves_time)
    _ = Application.ensure_all_started(:nerves_hub_link)
    NameBadge.Network.wifi_on()
  end

  defp set_cores(:b) do
    :erlang.system_flag(:schedulers_online, 1)
    File.write!("/sys/devices/system/cpu/cpu1/online", "0")
    Logger.info("PowerTest: CPU1 offline, 1 scheduler")
  end

  defp set_cores(phase) when phase in [:a1, :a2] do
    File.write!("/sys/devices/system/cpu/cpu1/online", "1")
    :erlang.system_flag(:schedulers_online, :erlang.system_info(:schedulers))
    Logger.info("PowerTest: CPU1 online, all schedulers")
  end

  defp sample_leg(phase) do
    t0 = System.monotonic_time(:millisecond)
    collect_samples(phase, t0, [])
  end

  defp collect_samples(phase, t0, acc) do
    elapsed_s = (System.monotonic_time(:millisecond) - t0) / 1000

    if elapsed_s * 1000 >= @leg_ms do
      Enum.reverse(acc)
    else
      if NameBadge.Battery.charging?(), do: throw(:usb_plugged)

      mv_ema = NameBadge.Battery.voltage() * 1000
      mv_raw = raw_burst_mv(25)
      write_sample(phase, elapsed_s, mv_ema, mv_raw)

      Process.sleep(@sample_ms)
      collect_samples(phase, t0, [{elapsed_s, mv_raw} | acc])
    end
  end

  defp write_sample(phase, elapsed_s, mv_ema, mv_raw) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    {idle0, idle1} = idle_ticks()

    line =
      Enum.join(
        [
          ts,
          phase,
          :erlang.float_to_binary(elapsed_s / 1, decimals: 1),
          :erlang.float_to_binary(mv_ema / 1, decimals: 2),
          :erlang.float_to_binary(mv_raw / 1, decimals: 2),
          load1(),
          cpu_temp(),
          idle0,
          idle1
        ],
        ","
      )

    File.write!(@csv, line <> "\n", [:append])
  end

  # Averages n direct ADC reads to beat per-read noise; the burst takes ~n ms,
  # far shorter than the 5 s sample cadence.
  defp raw_burst_mv(n) do
    sum =
      Enum.reduce(1..n, 0, fn _, acc ->
        raw = @adc_path |> File.read!() |> String.trim() |> String.to_integer()
        acc + raw
      end)

    sum / n / 4095.0 * 1.8 * 9.8823529412 * 1000
  end

  defp load1 do
    case File.read("/proc/loadavg") do
      {:ok, s} -> s |> String.split() |> hd()
      _ -> "-"
    end
  end

  defp cpu_temp do
    case File.read("/sys/class/thermal/thermal_zone0/temp") do
      {:ok, s} -> String.trim(s)
      _ -> "-"
    end
  end

  defp idle_ticks do
    case File.read("/proc/stat") do
      {:ok, stat} ->
        ticks =
          for line <- String.split(stat, "\n"),
              String.starts_with?(line, "cpu0") or String.starts_with?(line, "cpu1"),
              into: %{} do
            [name, _user, _nice, _sys, idle | _] = String.split(line)
            {name, idle}
          end

        {Map.get(ticks, "cpu0", "-"), Map.get(ticks, "cpu1", "-")}

      _ ->
        {"-", "-"}
    end
  end

  @doc """
  Least-squares voltage slope in mV/h over a leg's samples, excluding the
  first `#{@discard_s}` s (relaxation transient). Negative = draining.

  @example `slope_mv_h([{200.0, 3700.0}, {800.0, 3699.0}]) // -6.0`
  """
  def slope_mv_h(samples) do
    pts = Enum.filter(samples, fn {t, _} -> t >= @discard_s end)
    n = length(pts)
    t_mean = (pts |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / n
    v_mean = (pts |> Enum.map(&elem(&1, 1)) |> Enum.sum()) / n

    num = Enum.reduce(pts, 0.0, fn {t, v}, acc -> acc + (t - t_mean) * (v - v_mean) end)
    den = Enum.reduce(pts, 0.0, fn {t, _}, acc -> acc + (t - t_mean) * (t - t_mean) end)

    num / den * 3600
  end

  defp report(slopes) do
    a1 = Keyword.fetch!(slopes, :a1)
    b = Keyword.fetch!(slopes, :b)
    a2 = Keyword.fetch!(slopes, :a2)

    a_interp = (a1 + a2) / 2
    delta = b - a_interp
    pct = if a_interp != 0, do: delta / abs(a_interp) * 100, else: 0.0

    summary = """
    CPU core A/B drain test (#{DateTime.utc_now() |> DateTime.to_iso8601()})
    A1 (2 cores): #{fmt(a1)} mV/h
    B  (1 core):  #{fmt(b)} mV/h
    A2 (2 cores): #{fmt(a2)} mV/h
    A interpolated at B midpoint: #{fmt(a_interp)} mV/h
    Delta (B - A): #{fmt(delta)} mV/h (#{fmt(pct)}% of baseline drain)
    Positive delta = single-core drains slower = savings.
    """

    File.write!(@result, summary)
    Logger.info("PowerTest done:\n" <> summary)

    screen("""
    = CPU CORE TEST DONE
    #table(
      columns: 2,
      stroke: none,
      [A1, 2 cores], [#{fmt(a1)} mV/h],
      [B, 1 core], [#{fmt(b)} mV/h],
      [A2, 2 cores], [#{fmt(a2)} mV/h],
    )

    *Delta: #{fmt(delta)} mV/h (#{fmt(pct)}%)*

    Positive = savings. WiFi is back on.
    """)
  end

  defp fmt(f), do: :erlang.float_to_binary(f / 1, decimals: 1)

  defp screen(body) do
    markup = """
    #set page(width: 400pt, height: 300pt, margin: 28pt)
    #set text(font: "Poppins", size: 15pt)
    #show heading: set text(size: 20pt)
    """ <> body

    NameBadge.Display.render_typst(markup)
  end
end
