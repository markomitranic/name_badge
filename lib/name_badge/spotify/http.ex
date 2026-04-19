defmodule NameBadge.Spotify.HTTP do
  @moduledoc """
  Thin Req wrapper for Spotify Web API calls. Adds the Bearer header and
  retries once on HTTP 401 after forcing a token refresh — mirrors
  MusaicFM's `recovery()` pattern in Manager.m:286-320.
  """

  require Logger

  alias NameBadge.Spotify.Tokens

  @base "https://api.spotify.com"

  @doc """
  GET a Spotify API path. Accepts either a full URL or a path starting with
  "/v1/..." (the base is prepended). Returns `{:ok, %Req.Response{}}` or
  `{:error, reason}`.
  """
  def get(path, opts \\ []) do
    request(:get, path, opts)
  end

  defp request(method, path, opts, retries_left \\ 1) do
    with {:ok, token} <- Tokens.access_token(),
         url <- resolve(path),
         {:ok, resp} <- send_request(method, url, token, opts) do
      case resp.status do
        401 when retries_left > 0 ->
          Logger.info("Spotify 401, refreshing token and retrying once")
          _ = Tokens.force_refresh()
          request(method, path, opts, retries_left - 1)

        _ ->
          {:ok, resp}
      end
    end
  end

  defp send_request(method, url, token, opts) do
    headers = [{"authorization", "Bearer #{token}"}]
    req_opts = Keyword.merge([headers: headers, receive_timeout: 10_000], opts)

    Req.request([method: method, url: url] ++ req_opts)
  end

  defp resolve("http" <> _ = url), do: url
  defp resolve(path), do: @base <> path
end
