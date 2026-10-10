defmodule NameBadge.Spotify.ArtCache do
  @moduledoc """
  Disk-backed queue of prefetched, display-ready album covers.

  Covers are downloaded in batches and stored under `/data/spotify_art` as
  `<id>.png` + `<id>.json` metadata pairs, so the screen can rotate albums
  without touching the network. When the queue
  drops below a low-water mark, a background task tops it back up to a full
  batch. The queue survives reboots.

  Batching exists to make network usage bursty: one short online window
  refills ~35 minutes of rotation, which is what lets WiFi stay powered
  down in between.
  """

  use GenServer
  require Logger

  alias NameBadge.{Battery, Diagnostics, Network}
  alias NameBadge.Spotify.{Album, Art, Library, Tokens}

  @batch_size 10
  @low_water 3
  @failure_cooldown :timer.minutes(3)
  @call_timeout :timer.seconds(30)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Pops the oldest prefetched cover, or returns `nil` when the queue is
  empty. Kicks off a background refill when the queue runs low.

  @example `ArtCache.take() // %{png: <<...>>, artist: "Nirvana", album: "In Utero"}`
  """
  def take do
    GenServer.call(__MODULE__, :take, @call_timeout)
  catch
    :exit, _ -> nil
  end

  @impl GenServer
  def init(:ok) do
    File.mkdir_p!(cache_dir())
    {:ok, %{refill_task: nil, cooldown_until: nil}}
  end

  # A take with no refill in flight also powers WiFi down (a no-op when
  # it's already off): the chip should only be up during refill bursts.
  @impl GenServer
  def handle_call(:take, _from, state) do
    cover = pop_entry()
    state = maybe_refill(state)

    if state.refill_task == nil, do: Network.wifi_off()

    Logger.info("Spotify art cache: #{count_entries()} covers on disk after take")

    {:reply, cover, state}
  end

  # cooldown_until is a monotonic-clock deadline or nil. It must never be
  # compared against a literal 0 — BEAM monotonic time starts hugely negative,
  # so 0 would read as "in cooldown" for the first ~18 years of uptime.
  defp maybe_refill(state) do
    missing = @batch_size - count_entries()

    cond do
      state.refill_task != nil -> state
      in_cooldown?(state) -> state
      @batch_size - missing >= @low_water -> state
      not Tokens.configured?() -> state
      Battery.low?() -> state
      true -> start_refill(state, missing)
    end
  end

  defp in_cooldown?(%{cooldown_until: nil}), do: false

  defp in_cooldown?(%{cooldown_until: deadline}) do
    System.monotonic_time(:millisecond) < deadline
  end

  # WiFi goes back down as soon as the burst ends, however it ended.
  @impl GenServer
  def handle_info({ref, added}, %{refill_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Logger.info("Spotify art cache refill added #{added} covers")
    Network.wifi_off()

    cooldown =
      if added == 0 do
        System.monotonic_time(:millisecond) + @failure_cooldown
      else
        nil
      end

    {:noreply, %{state | refill_task: nil, cooldown_until: cooldown}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refill_task: %Task{ref: ref}} = state) do
    Logger.warning("Spotify art cache refill crashed: #{inspect(reason)}")
    Network.wifi_off()
    cooldown = System.monotonic_time(:millisecond) + @failure_cooldown
    {:noreply, %{state | refill_task: nil, cooldown_until: cooldown}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Queue on disk ----

  defp pop_entry do
    case list_ids() do
      [] ->
        nil

      [id | _] ->
        meta_path = Path.join(cache_dir(), id <> ".json")
        png_path = Path.join(cache_dir(), id <> ".png")

        result =
          with {:ok, meta_json} <- File.read(meta_path),
               {:ok, png} <- File.read(png_path),
               %{"artist" => artist, "album" => album} <- decode_meta(meta_json) do
            %{png: png, artist: artist, album: album}
          else
            _ -> nil
          end

        File.rm(meta_path)
        File.rm(png_path)
        result || pop_entry()
    end
  end

  defp list_ids do
    cache_dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&Path.rootname/1)
    |> Enum.sort()
  end

  defp count_entries, do: length(list_ids())

  defp decode_meta(json) do
    :json.decode(json)
  rescue
    _ -> nil
  end

  # ---- Refill ----

  defp start_refill(state, missing) do
    task =
      Task.Supervisor.async_nolink(NameBadge.TaskSupervisor, fn ->
        Diagnostics.measure(:art_refill, fn -> refill(missing) end)
      end)

    %{state | refill_task: task}
  end

  defp refill(count) do
    Network.wifi_on()

    case Network.await_internet() do
      :ok ->
        Enum.count(1..count, fn _ -> prefetch_one() == :ok end)

      {:error, :timeout} ->
        Logger.warning("Spotify art refill skipped: no internet")
        0
    end
  end

  defp prefetch_one do
    with %Album{image_url: url} = album when is_binary(url) <- Library.random_album(),
         {:ok, png} <- Art.fetch(url) do
      store(album, png)
    else
      other ->
        Logger.warning("Spotify cover prefetch failed: #{inspect(other)}")
        :error
    end
  end

  # The .png is written before the .json because `pop_entry/0` keys off the
  # .json file — an entry only becomes visible once both files exist.
  defp store(%Album{name: name, artist: artist}, png) do
    id = "#{System.os_time(:millisecond)}_#{System.unique_integer([:positive])}"
    meta = :json.encode(%{"artist" => artist, "album" => name})

    File.write!(Path.join(cache_dir(), id <> ".png"), png)
    File.write!(Path.join(cache_dir(), id <> ".json"), meta)
    :ok
  end

  defp cache_dir, do: "/data/spotify_art"
end
