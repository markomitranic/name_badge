defmodule NameBadge.Diagnostics do
  @moduledoc """
  Crash forensics that survive reboots. All of it is off by default.

  Three independent recorders, each switched on from `NameBadge.Application`:
  a warning+ log on disk, a boot marker per start, and this GenServer, which
  persists minute health samples plus operation timings. Two 2 MB sample
  files rotate; kernel snapshots retain the current and previous boot.
  Sampling never calls the monitored GenServers. While the GenServer is not
  running, `measure/2` and `event/1` cost a dropped cast and nothing more.
  """

  use GenServer

  @sample_interval :timer.minutes(1)
  @max_log_bytes 2_000_000
  @max_kernel_bytes 65_536

  @monitored [
    NameBadge.Diagnostics,
    NameBadge.Display,
    NameBadge.Screen,
    NameBadge.Button,
    EInk
  ]

  @doc """
  Persists warning+ log entries, including crash reports, to /data/debug.log
  (2 x 512 KB, rotated). RingLogger is RAM-only and loses them on reboot.

  @example `Diagnostics.attach_disk_logger() // :ok`
  """
  def attach_disk_logger() do
    _ =
      :logger.add_handler(:disk_log, :logger_std_h, %{
        config: %{file: ~c"/data/debug.log", max_no_bytes: 512_000, max_no_files: 2},
        level: :warning
      })

    :ok
  end

  @doc """
  Appends a "ts,boot,voltage" line to /data/power.log. A boot line with
  no matching graceful /data/shutdown.txt means a hard reset (watchdog,
  brownout, power cut). The timestamp may be stale until NTP syncs.

  @example `Diagnostics.log_boot() // :ok`
  """
  def log_boot() do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    voltage = NameBadge.Battery.voltage() |> Float.round(4)
    File.write("/data/power.log", "#{ts},boot,#{voltage}\n", [:append])
    :ok
  end

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
      voltage: NameBadge.Battery.voltage() |> Float.round(4)
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

  defp read_text(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents)
      _error -> ""
    end
  end

  defp elapsed_since(started_at), do: System.monotonic_time(:millisecond) - started_at
end
