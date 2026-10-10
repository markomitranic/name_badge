defmodule NameBadge.Button do
  @moduledoc """
  Watches button A and tells the Spotify screen the moment it goes down.

  Fires on press rather than release so the e-ink starts redrawing as
  early as possible. Contact bounce can fire it more than once; the screen
  drops presses that queued up while it was busy drawing.
  """

  use GenServer

  @gpio "BTN_1"

  def start_link(target) do
    GenServer.start_link(__MODULE__, target, name: __MODULE__)
  end

  @impl GenServer
  def init(target) do
    {:ok, gpio} = Circuits.GPIO.open(@gpio, :input)
    :ok = Circuits.GPIO.set_interrupts(gpio, :falling)

    {:ok, %{gpio: gpio, target: target}}
  end

  @impl GenServer
  def handle_info({:circuits_gpio, _gpio, _timestamp, 0}, state) do
    if screen = Process.whereis(state.target), do: send(screen, :button_pressed)
    {:noreply, state}
  end

  def handle_info({:circuits_gpio, _gpio, _timestamp, _released}, state) do
    {:noreply, state}
  end
end
