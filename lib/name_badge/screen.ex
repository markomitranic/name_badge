defmodule NameBadge.Screen do
  @moduledoc """
  The badge's only screen: plays the pre-rendered album frames in
  /data/covers in shuffled order, one every 5 minutes. Button A skips.

  Frames are finished 4-level images rendered on the laptop
  (`scripts/sync.exs`) and pushed over USB (`scripts/push_covers.exs`), so a
  rotation is just "read a file, draw it". The whole library plays once
  before anything repeats.
  """

  use GenServer

  require Logger

  alias NameBadge.Display

  @covers_dir "/data/covers"
  @rotate_interval :timer.minutes(5)

  # Frames already hold exactly the four calibrated gray levels, so the
  # driver must not dither them again. Add `anti_ghost: true` for a white
  # flush before each draw if covers start leaving visible residue.
  @draw_opts [mode: :grayscale, dither: false]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Re-reads /data/covers and shows a fresh cover right away. Called after a push.

  @example `NameBadge.Screen.reload() // :ok`
  """
  def reload do
    send(__MODULE__, :reload)
    :ok
  end

  @impl GenServer
  def init(:ok) do
    send(self(), :rotate)
    {:ok, %{queue: [], timer: nil}}
  end

  @impl GenServer
  def handle_info(:rotate, state) do
    {:noreply, rotate(state)}
  end

  def handle_info(:button_pressed, state) do
    state = cancel_timer(state)
    state = rotate(state)
    drop_queued(:button_pressed)

    {:noreply, state}
  end

  def handle_info(:reload, state) do
    state = cancel_timer(state)
    {:noreply, rotate(%{state | queue: []})}
  end

  # ---- Rotation ----

  defp rotate(state) do
    case next_cover(state.queue) do
      {nil, []} ->
        Display.render_png(empty_frame(), @draw_opts)
        %{state | queue: []}

      {path, queue} ->
        Display.render_png(File.read!(path), @draw_opts)
        %{state | queue: queue, timer: Process.send_after(self(), :rotate, @rotate_interval)}
    end
  end

  # Pops the next cover, reshuffling the library when a pass ends. Covers a
  # push deleted since the shuffle are skipped.
  defp next_cover([]) do
    case shuffled_library() do
      [] -> {nil, []}
      queue -> next_cover(queue)
    end
  end

  defp next_cover([path | rest]) do
    if File.exists?(path), do: {path, rest}, else: next_cover(rest)
  end

  defp shuffled_library do
    Path.join(@covers_dir, "*.png")
    |> Path.wildcard()
    |> Enum.shuffle()
  end

  defp empty_frame do
    :name_badge
    |> Application.app_dir("priv/no_covers.png")
    |> File.read!()
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    drop_queued(:rotate)
    %{state | timer: nil}
  end

  # Presses that bounced or queued up during a ~1.3 s draw, and a timer
  # that fired just before a skip, would otherwise each rotate again.
  defp drop_queued(message) do
    receive do
      ^message -> drop_queued(message)
    after
      0 -> :ok
    end
  end
end
