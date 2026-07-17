defmodule NameBadge.PowerMonitor do
  @moduledoc """
  Keeps WiFi on whenever USB power is present.

  Complements the "WiFi never turns off while USB-powered" guard in
  `NameBadge.Network.wifi_off/0`: the guard covers power-off attempts while
  charging, this monitor covers the chip being off while charging for any
  other reason — plugged in after the Spotify screen powered it down, or
  stranded off by a crash that skipped the screen's terminate callback.
  """

  use GenServer

  @poll_interval :timer.seconds(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :timer.send_interval(@poll_interval, :poll)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    if NameBadge.Battery.charging?() and not NameBadge.Network.wifi_present?() do
      NameBadge.Network.wifi_on()
    end

    {:noreply, state}
  end
end
