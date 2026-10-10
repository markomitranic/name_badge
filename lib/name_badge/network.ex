defmodule NameBadge.Network do
  @moduledoc """
  Switches the WiFi chip on and off at runtime without touching the
  persisted config, so a reboot always comes back with WiFi configured.
  """

  require Logger

  alias NameBadge.Battery

  @doc """
  Powers the WiFi chip back on by restoring the runtime config that
  `wifi_off/0` stashed. No-op when WiFi is already configured.

  @example `Network.wifi_on() // :ok`
  """
  def wifi_on() do
    case VintageNet.get_configuration("wlan0") do
      %{type: VintageNet.Technology.Null} ->
        case :persistent_term.get({__MODULE__, :wifi_config}, nil) do
          nil ->
            Logger.warning("Network.wifi_on: no stashed wlan0 config to restore")

          config ->
            Logger.info("Network: powering WiFi on")
            VintageNet.configure("wlan0", config, persist: false)
        end

      _already_configured ->
        :ok
    end

    :ok
  end

  @doc """
  Hard-powers the WiFi chip off (cuts the WIFI_EN line via the VintageNet
  power manager) and stashes the config for `wifi_on/0`. No-op when already
  off, and refused while USB-powered: on external power WiFi stays on.

  @example `Network.wifi_off() // :ok`
  """
  def wifi_off() do
    config = VintageNet.get_configuration("wlan0")

    cond do
      match?(%{type: VintageNet.Technology.Null}, config) ->
        :ok

      Battery.charging?() ->
        Logger.info("Network: WiFi stays on (USB-powered)")

      true ->
        :persistent_term.put({__MODULE__, :wifi_config}, config)
        Logger.info("Network: powering WiFi off")
        VintageNet.deconfigure("wlan0", persist: false)
    end

    :ok
  end

  @doc """
  Blocks until wlan0 reaches `:internet`, polling once a second. Returns
  `:ok`, or `{:error, :timeout}` after `timeout` ms.

  @example `Network.await_internet(30_000) // :ok`
  """
  def await_internet(timeout \\ :timer.seconds(60)) do
    poll_internet(System.monotonic_time(:millisecond) + timeout)
  end

  @doc """
  Whether the WiFi chip is physically powered and enumerated (wlan0 exists).
  Tracks the WIFI_EN hard power-off, unlike the `connection` property which
  flips as soon as a deconfigure is requested.

  @example `Network.wifi_present?() // false`
  """
  def wifi_present?() do
    VintageNet.get(["interface", "wlan0", "present"]) == true
  end

  defp poll_internet(deadline) do
    cond do
      VintageNet.get(["interface", "wlan0", "connection"]) == :internet ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(1_000)
        poll_internet(deadline)
    end
  end
end
