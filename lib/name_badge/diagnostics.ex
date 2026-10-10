defmodule NameBadge.Diagnostics do
  @moduledoc """
  Persists minute health samples and operation timings for crash investigations.

  Two 2 MB log files survive restarts. Kernel snapshots retain the current and
  previous boot. Sampling never calls the monitored GenServers.
  """

  use GenServer

  @sample_interval :timer.minutes(1)
  @max_log_bytes 2_000_000
  @max_kernel_bytes 65_536

  @monitored [
    NameBadge.Diagnostics,
    NameBadge.Display,
    EInk,
    NameBadge.Battery,
    NameBadge.PowerMonitor,
    NameBadge.ScreenManager,
    NameBadge.Spotify.ArtCache,
    NameBadge.Spotify.Library,
    NameBadge.Spotify.Tokens,
    VintageNet.RouteManager,
    VintageNet.Updater
  ]

  @doc "Starts the device health recorder with an optional storage directory."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records an operation's start and completion, returning its original result.

  Failures retain their original stacktrace. Arguments and results are never logged.

  @example Diagnostics.measure(:draw, fn -> :ok end) #=> :ok
  """
  def measure(operation, fun) do
    id = System.unique_integer([:positive, :monotonic])
    started_at = System.monotonic_time(:millisecond)

    event(%{event: :start, id: id, operation: operation})

    try do
      result = fun.()

      event(%{
        event: :finish,
        id: id,
        operation: operation,
        elapsed_ms: elapsed_since(started_at)
      })

      result
    catch
      kind, reason ->
        event(%{
          event: :failed,
          id: id,
          operation: operation,
          kind: kind,
          elapsed_ms: elapsed_since(started_at)
        })

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Queues a small diagnostic event without waiting for disk or another service."
  def event(fields) do
    entry =
      Map.merge(fields, %{
        utc: DateTime.utc_now() |> DateTime.to_iso8601(),
        monotonic_ms: System.monotonic_time(:millisecond),
        pid: inspect(self())
      })

    GenServer.cast(__MODULE__, {:event, entry})
  end

  @impl GenServer
  def init(opts) do
    dir = Keyword.get(opts, :dir, "/data")
    File.mkdir_p!(dir)

    boot = read_text("/proc/sys/kernel/random/boot_id")
    rotate_kernel_snapshot(dir, boot)

    event(%{event: :recorder_started, version: 1, boot_id: boot})
    send(self(), :sample)

    {:ok, %{dir: dir, boot: boot}}
  end

  @impl GenServer
  def handle_cast({:event, entry}, state) do
    append(state.dir, Map.put(entry, :boot_id, state.boot))
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sample, state) do
    event(%{
      event: :health,
      uptime: read_text("/proc/uptime"),
      loadavg: read_text("/proc/loadavg"),
      cpu: "/proc/stat" |> read_text() |> String.split("\n") |> hd(),
      meminfo: memory_lines(),
      beam_memory: Map.new(:erlang.memory()),
      run_queue: :erlang.statistics(:run_queue),
      scheduler_queues: :erlang.statistics(:run_queue_lengths_all),
      normal_schedulers: :erlang.system_info(:schedulers),
      processes: Map.new(@monitored, &process_sample/1),
      voltage: voltage(),
      wifi_present: File.exists?("/sys/class/net/wlan0"),
      wifi_state: read_text("/sys/class/net/wlan0/operstate")
    })

    snapshot_kernel(state.dir)
    Process.send_after(self(), :sample, @sample_interval)

    {:noreply, state}
  end

  defp rotate_kernel_snapshot(dir, boot) do
    boot_id_path = Path.join(dir, "health-boot-id")

    if read_text(boot_id_path) != boot do
      File.rename(
        Path.join(dir, "health-kernel.log"),
        Path.join(dir, "health-kernel.previous.log")
      )

      File.write(boot_id_path, boot)
    end
  end

  defp snapshot_kernel(dir) do
    case System.cmd("dmesg", [], stderr_to_stdout: true) do
      {output, 0} ->
        size = byte_size(output)
        kept = min(size, @max_kernel_bytes)

        write_if_changed(
          Path.join(dir, "health-kernel.log"),
          binary_part(output, size - kept, kept)
        )

      _failed ->
        :ok
    end
  catch
    :error, _reason -> :ok
  end

  defp write_if_changed(path, contents) do
    tmp = path <> ".tmp"

    if File.read(path) != {:ok, contents} do
      with :ok <- File.write(tmp, contents, [:sync]), do: File.rename(tmp, path)
    end
  end

  defp append(dir, entry) do
    path = Path.join(dir, "health.jsonl")
    line = [JSON.encode!(entry), "\n"]

    with {:ok, %{size: size}} <- File.stat(path),
         true <- size + IO.iodata_length(line) > @max_log_bytes do
      File.rename(path, path <> ".1")
    end

    File.write(path, line, [:append, :sync])
  end

  defp memory_lines do
    "/proc/meminfo"
    |> read_text()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, ["MemAvailable:", "MemFree:", "SwapFree:", "Slab:"]))
  end

  defp process_sample(name) do
    info =
      case Process.whereis(name) do
        nil ->
          nil

        pid ->
          Process.info(pid, [:message_queue_len, :memory, :reductions, :status, :current_function])
      end

    {inspect(name), inspect(info)}
  end

  defp voltage do
    case "/sys/bus/iio/devices/iio:device0/in_voltage0_raw" |> read_text() |> Integer.parse() do
      {raw, _rest} -> Float.round(raw / 4095.0 * 1.8 * 9.8823529412, 4)
      :error -> nil
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      _error -> ""
    end
  end

  defp elapsed_since(started_at), do: System.monotonic_time(:millisecond) - started_at
end
