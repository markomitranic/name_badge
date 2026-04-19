defmodule NameBadge.Spotify.Library do
  @moduledoc """
  Picks a random album from the user's Spotify saved library, **without**
  loading the whole library.

  Caches only the library size (`total`). On each `random_album/0` call:
  1. If `total` is missing or older than 24 h, query `/v1/me/albums?limit=1`
     to pick up the current size.
  2. Pick a random offset in `[0, total)`.
  3. Fetch exactly that album with `/v1/me/albums?limit=1&offset=N`.

  Contrast with MusaicFM, which paginates the whole library (20+ requests
  for a 1000-album library) because it fills a grid with many tiles. For
  one-at-a-time rotation on a small display, a random slice is much cheaper
  and always reflects the current library without a stale cache.
  """

  use GenServer
  require Logger

  alias NameBadge.Spotify.{Album, HTTP, Tokens}

  @total_ttl :timer.hours(24)
  @call_timeout 20_000

  defstruct total: nil, fetched_at: nil

  # ---- Client API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Returns one random album from the user's saved library, or `nil` if the
  library is empty / the API call fails.
  """
  def random_album do
    GenServer.call(__MODULE__, :random_album, @call_timeout)
  catch
    :exit, {:noproc, _} -> nil
    :exit, {:timeout, _} -> nil
  end

  @doc "Invalidates the cached total so the next call re-queries Spotify."
  def invalidate do
    GenServer.cast(__MODULE__, :invalidate)
  end

  # ---- Server ----

  @impl GenServer
  def init(:ok) do
    {:ok, load_cache()}
  end

  @impl GenServer
  def handle_call(:random_album, _from, state) do
    if Tokens.configured?() do
      with {:ok, state} <- ensure_total(state),
           %Album{} = album <- fetch_random_album(state) do
        {:reply, album, state}
      else
        _ -> {:reply, nil, state}
      end
    else
      {:reply, nil, state}
    end
  end

  @impl GenServer
  def handle_cast(:invalidate, _state) do
    {:noreply, %__MODULE__{}}
  end

  # ---- Total (library size) ----

  defp ensure_total(%__MODULE__{total: t, fetched_at: at} = state)
       when is_integer(t) and not is_nil(at) do
    if fresh?(at) do
      {:ok, state}
    else
      refresh_total(state)
    end
  end

  defp ensure_total(state), do: refresh_total(state)

  defp fresh?(fetched_at) do
    DateTime.diff(DateTime.utc_now(), fetched_at, :millisecond) < @total_ttl
  end

  defp refresh_total(state) do
    case HTTP.get("/v1/me/albums?limit=1&offset=0") do
      {:ok, %{status: 200, body: body}} ->
        total = body["total"] || 0
        Logger.info("Spotify library size: #{total}")
        new_state = %{state | total: total, fetched_at: DateTime.utc_now()}
        persist_cache(new_state)
        {:ok, new_state}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Spotify library total fetch failed: HTTP #{status} #{inspect(body)}")
        :error

      {:error, reason} ->
        Logger.warning("Spotify library total fetch network error: #{inspect(reason)}")
        :error
    end
  end

  # ---- Single random album ----

  defp fetch_random_album(%__MODULE__{total: total}) when is_integer(total) and total > 0 do
    offset = :rand.uniform(total) - 1

    case HTTP.get("/v1/me/albums?limit=1&offset=#{offset}") do
      {:ok, %{status: 200, body: %{"items" => [%{"album" => album} | _]}}} ->
        parse_album(album)

      {:ok, %{status: 200, body: %{"items" => []}}} ->
        Logger.warning("Spotify returned empty items at offset #{offset}/#{total}")
        nil

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Spotify random album fetch failed: HTTP #{status} #{inspect(body)}")
        nil

      {:error, reason} ->
        Logger.warning("Spotify random album network error: #{inspect(reason)}")
        nil
    end
  end

  defp fetch_random_album(_), do: nil

  defp parse_album(%{"name" => name, "artists" => artists, "images" => images}) do
    %Album{
      name: name,
      artist: artists |> List.first() |> Map.get("name", "Unknown"),
      image_url: closest_image(images)
    }
  end

  defp parse_album(_), do: nil

  defp closest_image([]), do: nil
  defp closest_image(nil), do: nil

  defp closest_image(images) do
    images
    |> Enum.min_by(fn img -> abs((img["width"] || 0) - 300) end)
    |> Map.get("url")
  end

  # ---- Persistence ----

  defp persist_cache(%__MODULE__{total: total, fetched_at: at}) do
    payload = %{"total" => total, "fetched_at" => DateTime.to_iso8601(at)}
    File.mkdir_p(Path.dirname(cache_file()))
    File.write(cache_file(), :json.encode(payload))
  catch
    kind, err ->
      Logger.warning("Could not persist Spotify library cache: #{inspect({kind, err})}")
      :ok
  end

  defp load_cache do
    with {:ok, json} <- File.read(cache_file()),
         %{} = map <- :json.decode(json),
         total when is_integer(total) <- Map.get(map, "total"),
         iso when is_binary(iso) <- Map.get(map, "fetched_at"),
         {:ok, at, _} <- DateTime.from_iso8601(iso) do
      Logger.info("Spotify.Library loaded cached total=#{total} from #{iso}")
      %__MODULE__{total: total, fetched_at: at}
    else
      _ -> %__MODULE__{}
    end
  rescue
    _ -> %__MODULE__{}
  end

  if Mix.target() == :host do
    defp cache_file do
      System.tmp_dir!()
      |> Path.join("spotify_library.json")
    end
  else
    defp cache_file, do: "/data/spotify_library.json"
  end
end
