defmodule NameBadge.Battery do
  @moduledoc """
  Reads the battery voltage straight from the ADC and interprets it.

  Stateless: every call is one sysfs read, so nothing polls in the
  background and no caller can be starved waiting on a busy process.
  """

  @adc_path "/sys/bus/iio/devices/iio:device0/in_voltage0_raw"

  # raw / 4095 (12-bit ADC) * 1.8 V reference * (453k + 51k) / 51k divider
  @volts_per_count 1.8 / 4095 * 9.8823529412

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
  Current input voltage. On USB power this reads the input rail (> 4.5 V).

  @example `Battery.voltage() // 3.82`
  """
  def voltage() do
    @adc_path
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
    |> Kernel.*(@volts_per_count)
  end

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
end
