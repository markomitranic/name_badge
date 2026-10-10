defmodule NameBadge.Battery do
  use GenServer

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Reading the cached voltage is instant, but the process can be starved for
  # seconds while the art refill saturates both cores — and every status bar
  # render asks twice. The 5 s call default made that starvation crash the
  # caller instead of just making it slow.
  @call_timeout :timer.seconds(30)

  def voltage(), do: GenServer.call(__MODULE__, :get_voltage, @call_timeout)

  # Measured on this badge (2026-10, two full drains with WiFi on, 6-7 h
  # each): remaining runtime as a fraction of the whole drain, against the
  # minute-sampled ADC voltage. Li-ion sags fast at both ends and sits on a
  # long flat plateau around 3.6-3.7 V, which a linear map reads as "half
  # full" right before the badge dies.
  @discharge_curve [
    {4.10, 100},
    {4.01, 90},
    {3.90, 80},
    {3.83, 70},
    {3.75, 60},
    {3.69, 50},
    {3.66, 40},
    {3.63, 30},
    {3.60, 20},
    {3.55, 10},
    {3.49, 5},
    {3.35, 0}
  ]

  # The WiFi chip's power-on surge browned the board out mid-refill at
  # 3.56 V (it survived at 3.57 V). Below this, nothing should power it up
  # on its own. Roughly 35% on the curve above.
  @low_voltage 3.65

  @doc """
  Whether the badge is on USB power. The ADC reads the input rail, which
  sits above 4.5 V whenever a cable is plugged in.

  @example `Battery.charging?() // true`
  """
  def charging?(), do: voltage() > 4.5

  @doc """
  Whether the battery is too low to risk powering the WiFi chip on. Never
  true on USB power, since that reads above 4.5 V.

  @example `Battery.low?() // false`
  """
  def low?(), do: voltage() < @low_voltage

  @doc """
  Remaining charge as 0-100, interpolated along the measured discharge curve.

  @example `Battery.percentage() // 42`
  """
  def percentage(), do: voltage() |> percentage_at()

  @doc """
  Maps a battery voltage to 0-100 along the measured discharge curve.

  @example `Battery.percentage_at(3.69) // 50`
  """
  def percentage_at(voltage) do
    case Enum.split_while(@discharge_curve, fn {point, _} -> point > voltage end) do
      {[], _below} ->
        100

      {_above, []} ->
        0

      {above, [{low_v, low_pct} | _]} ->
        {high_v, high_pct} = List.last(above)
        round(low_pct + (voltage - low_v) / (high_v - low_v) * (high_pct - low_pct))
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, 500)
    alpha = Keyword.get(opts, :alpha, 0.9)

    timer = :timer.send_interval(interval, :update)

    {:ok, %{interval: interval, alpha: alpha, timer: timer, voltage: read_voltage()}}
  end

  @impl true
  def handle_call(:get_voltage, _from, state) do
    {:reply, state.voltage, state}
  end

  @impl true
  def handle_info(:update, state) do
    # low pass filter (exponential average)
    state =
      update_in(state.voltage, fn v ->
        v * state.alpha + read_voltage() * (1 - state.alpha)
      end)

    {:noreply, state}
  end

  defp read_voltage do
    adc_raw =
      "/sys/bus/iio/devices/iio:device0/in_voltage0_raw"
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    # adc_raw / MAX_ADC_VALUE * ADC_REFERENCE_VOLTAGE * VOLTAGE_DIVIDER
    # On the PCB, the voltage divider is 453k and 51k resistors
    # So the value for the voltage divider is (453 + 51) / 51 = 9.8823529412
    # (the units cancel in this equation)

    adc_raw / 4095.0 * 1.8 * 9.8823529412
  end
end
