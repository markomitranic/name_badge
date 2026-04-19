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
end
