defmodule NameBadge.PowerMonitor do
  @moduledoc """
  Turns WiFi back on the moment USB power is plugged in.

  Complements the "WiFi never turns off while USB-powered" guard in
  `NameBadge.Network.wifi_off/0`: the guard covers power-off attempts while
  charging, this monitor covers plugging in after something (the Spotify
  screen) already powered the chip down.
  """

  use GenServer

  @poll_interval :timer.seconds(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :timer.send_interval(@poll_interval, :poll)
    {:ok, %{charging?: NameBadge.Battery.charging?()}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    charging? = NameBadge.Battery.charging?()

    if charging? and not state.charging?, do: NameBadge.Network.wifi_on()

    {:noreply, %{state | charging?: charging?}}
  end
end
