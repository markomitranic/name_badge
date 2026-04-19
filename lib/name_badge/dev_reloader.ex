if Mix.target() == :host do
  defmodule NameBadge.DevReloader do
    @moduledoc """
    Host-only file watcher that recompiles on save and pokes the PhoenixPlayground
    LiveView socket so the browser re-renders without a manual refresh.

    Compiles in-process via `Mix.Task.rerun/2` — no `mix` subprocess, so `mise`
    env rewriting (MIX_TARGET=trellis) can't break the reload loop.
    """
    use GenServer
    require Logger

    @throttle_ms 200
    @extensions ~w(.ex .eex .heex)

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      dirs = watch_dirs()
      {:ok, pid} = FileSystem.start_link(dirs: dirs)
      FileSystem.subscribe(pid)
      Logger.info("[dev_reloader] watching #{Enum.join(dirs, ", ")}")
      {:ok, %{watcher: pid, timer: nil}}
    end

    @impl true
    def handle_info({:file_event, pid, {path, _events}}, %{watcher: pid} = state) do
      if Path.extname(path) in @extensions and not tmp_file?(path) do
        {:noreply, schedule(state)}
      else
        {:noreply, state}
      end
    end

    def handle_info({:file_event, pid, :stop}, %{watcher: pid} = state),
      do: {:noreply, state}

    def handle_info(:recompile, state) do
      recompile_and_notify()
      {:noreply, %{state | timer: nil}}
    end

    def handle_info(_other, state), do: {:noreply, state}

    defp schedule(%{timer: nil} = state) do
      %{state | timer: Process.send_after(self(), :recompile, @throttle_ms)}
    end

    defp schedule(state), do: state

    defp watch_dirs do
      [Path.join(File.cwd!(), "lib")]
    end

    # editors often save via a temp file + rename; ignore those
    defp tmp_file?(path), do: String.contains?(path, ".tmp.")

    defp recompile_and_notify do
      Mix.Task.reenable("compile")
      Mix.Task.reenable("compile.elixir")

      case Mix.Task.rerun("compile", ["--ignore-module-conflict", "--return-errors"]) do
        {:error, diagnostics} ->
          Logger.error("[dev_reloader] compile failed: #{inspect(diagnostics)}")

        _ ->
          Logger.info("[dev_reloader] reloaded")

          Phoenix.PubSub.broadcast(
            PhoenixPlayground.PubSub,
            "live_view",
            {:phoenix_live_reload, :live_view, nil}
          )
      end
    rescue
      e -> Logger.error("[dev_reloader] #{Exception.format(:error, e, __STACKTRACE__)}")
    end
  end
end
