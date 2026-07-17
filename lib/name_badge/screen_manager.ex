defmodule NameBadge.ScreenManager do
  use GenServer

  require Logger

  alias NameBadge.Screen

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def navigate(:back) do
    GenServer.cast(__MODULE__, :back)
  end

  def navigate(module) do
    GenServer.cast(__MODULE__, {:navigate, module})
  end

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    initial_stack = [Screen.TopLevel]

    {:ok, pid} = Screen.start_link(module: hd(initial_stack))

    {:ok, %{stack: initial_stack, current_screen: pid}}
  end

  @impl GenServer
  def handle_cast({:navigate, module}, state) do
    Screen.shutdown(state.current_screen)
    {:ok, pid} = Screen.start_link(module: module)

    new_stack = [module | state.stack]

    {:noreply, %{state | stack: new_stack, current_screen: pid}}
  end

  def handle_cast(:back, state) do
    case tl(state.stack) do
      [] ->
        {:noreply, state}

      [previous_screen | _rest] = new_stack ->
        Screen.shutdown(state.current_screen)
        {:ok, pid} = Screen.start_link(module: previous_screen)

        {:noreply, %{state | stack: new_stack, current_screen: pid}}
    end
  end

  # A crashed screen skips its terminate/2 (where Spotify restores WiFi),
  # so recover deliberately: log the reason, put WiFi back on, go home.
  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{current_screen: pid} = state)
      when reason not in [:normal, :shutdown] do
    Logger.error("Screen #{inspect(hd(state.stack))} crashed: #{inspect(reason)}")
    NameBadge.Network.wifi_on()

    {:ok, new_pid} = Screen.start_link(module: Screen.TopLevel)
    {:noreply, %{state | stack: [Screen.TopLevel], current_screen: new_pid}}
  end

  def handle_info({:EXIT, _stale_screen, _reason}, state), do: {:noreply, state}
end
