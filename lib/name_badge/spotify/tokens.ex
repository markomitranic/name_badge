defmodule NameBadge.Spotify.Tokens do
  @moduledoc """
  Owns Spotify OAuth tokens. Reads client_id, client_secret, and refresh_token
  from app env at boot (plumbed from env vars via config/config.exs). Exchanges
  refresh_token for short-lived access_tokens on demand.

  Persists any rotated refresh_token returned by Spotify to a JSON file under
  /data (or tmp on host) so we survive reboots without needing to rebuild
  firmware every time Spotify rotates the token.
  """

  use GenServer
  require Logger

  @token_url "https://accounts.spotify.com/api/token"
  @skew_seconds 60
  @call_timeout 10_000

  defstruct [
    :client_id,
    :client_secret,
    :refresh_token,
    :access_token,
    :expires_at
  ]

  # ---- Client API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Returns true if all three credentials are present."
  def configured? do
    GenServer.call(__MODULE__, :configured?, @call_timeout)
  catch
    :exit, {:noproc, _} -> false
    :exit, {:timeout, _} -> false
  end

  @doc """
  Returns a fresh access token, refreshing from Spotify if needed.
  Returns `{:ok, token}` or `{:error, reason}`.
  """
  def access_token do
    GenServer.call(__MODULE__, :access_token, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc """
  Forces a refresh (drops cached access_token first). Useful after a 401.
  """
  def force_refresh do
    GenServer.call(__MODULE__, :force_refresh, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # ---- Server ----

  @impl GenServer
  def init(:ok) do
    env = Application.get_env(:name_badge, :spotify, [])
    persisted = load_persisted()

    state = %__MODULE__{
      client_id: env[:client_id],
      client_secret: env[:client_secret],
      refresh_token: persisted[:refresh_token] || env[:refresh_token]
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:configured?, _from, state) do
    {:reply, has_credentials?(state), state}
  end

  def handle_call(:access_token, _from, state) do
    case ensure_fresh_token(state) do
      {:ok, token, new_state} -> {:reply, {:ok, token}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:force_refresh, _from, state) do
    state = %{state | access_token: nil, expires_at: nil}

    case ensure_fresh_token(state) do
      {:ok, token, new_state} -> {:reply, {:ok, token}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  # ---- Token exchange ----

  defp ensure_fresh_token(%__MODULE__{} = state) do
    cond do
      not has_credentials?(state) ->
        {:error, :unauthorized, state}

      valid_token?(state) ->
        {:ok, state.access_token, state}

      true ->
        refresh_via_spotify(state)
    end
  end

  defp valid_token?(%{access_token: nil}), do: false
  defp valid_token?(%{expires_at: nil}), do: false

  defp valid_token?(%{expires_at: expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now()) > @skew_seconds
  end

  defp refresh_via_spotify(state) do
    body = URI.encode_query(%{
      "grant_type" => "refresh_token",
      "refresh_token" => state.refresh_token
    })

    auth = Base.encode64("#{state.client_id}:#{state.client_secret}")

    headers = [
      {"authorization", "Basic #{auth}"},
      {"content-type", "application/x-www-form-urlencoded"}
    ]

    case Req.post(@token_url, headers: headers, body: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} ->
        state = apply_token_response(state, body)
        {:ok, state.access_token, state}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"} = body}} ->
        Logger.warning("Spotify refresh_token revoked: #{inspect(body)}")
        clear_persisted()
        {:error, {:invalid_grant, status}, %{state | refresh_token: nil, access_token: nil, expires_at: nil}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Spotify token refresh failed: HTTP #{status} #{inspect(body)}")
        {:error, {:http_error, status}, state}

      {:error, reason} ->
        Logger.error("Spotify token refresh network error: #{inspect(reason)}")
        {:error, {:network, reason}, state}
    end
  end

  defp apply_token_response(state, body) do
    expires_in = Map.get(body, "expires_in", 3600)
    rotated = Map.get(body, "refresh_token")

    state =
      if is_binary(rotated) and rotated != "" and rotated != state.refresh_token do
        persist(%{refresh_token: rotated})
        %{state | refresh_token: rotated}
      else
        state
      end

    %{
      state
      | access_token: Map.fetch!(body, "access_token"),
        expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
    }
  end

  defp has_credentials?(%{client_id: c, client_secret: s, refresh_token: r})
       when is_binary(c) and is_binary(s) and is_binary(r) and c != "" and s != "" and r != "",
       do: true

  defp has_credentials?(_), do: false

  # ---- Persistence ----

  defp persist(map) do
    File.mkdir_p(Path.dirname(token_file()))
    File.write(token_file(), :json.encode(stringify_keys(map)))
  catch
    kind, err ->
      Logger.warning("Could not persist Spotify tokens: #{inspect({kind, err})}")
      :ok
  end

  defp load_persisted do
    case File.read(token_file()) do
      {:ok, json} ->
        case :json.decode(json) do
          %{} = map -> atomize_keys(map)
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp clear_persisted do
    _ = File.rm(token_file())
    :ok
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  if Mix.target() == :host do
    defp token_file do
      System.tmp_dir!()
      |> Path.join("spotify_tokens.json")
    end
  else
    defp token_file, do: "/data/spotify_tokens.json"
  end
end
