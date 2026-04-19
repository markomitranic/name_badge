#!/usr/bin/env elixir
# One-time Spotify authorization helper. Runs on your laptop (macOS / Linux),
# not on the badge. Mirrors MusaicFM's classic Authorization Code flow.
#
# Usage:
#   1. Register a Spotify app at https://developer.spotify.com/dashboard
#      - Redirect URI: http://127.0.0.1:8888/callback
#   2. Set env vars and run this script:
#
#        SPOTIFY_CLIENT_ID=xxx SPOTIFY_CLIENT_SECRET=yyy \
#          elixir scripts/spotify_auth.exs
#
#   3. Script opens your browser, you log in to Spotify, it captures the
#      code, exchanges it for a refresh token, and prints the three env
#      vars to paste into .mise.local.toml.

Mix.install([
  {:bandit, "~> 1.5"},
  {:plug, "~> 1.15"},
  {:req, "~> 0.5"}
])

defmodule SpotifyAuth do
  @port 8888
  @redirect_uri "http://127.0.0.1:#{8888}/callback"
  @scope "user-library-read"
  @authorize_url "https://accounts.spotify.com/authorize"
  @token_url "https://accounts.spotify.com/api/token"

  def run do
    client_id = require_env("SPOTIFY_CLIENT_ID")
    client_secret = require_env("SPOTIFY_CLIENT_SECRET")

    Process.register(self(), :spotify_auth_parent)

    {:ok, _server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, %{client_id: client_id, client_secret: client_secret}},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: @port
      )

    IO.puts("Local callback server on http://127.0.0.1:#{@port}")

    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    url =
      @authorize_url <>
        "?" <>
        URI.encode_query(%{
          "client_id" => client_id,
          "response_type" => "code",
          "redirect_uri" => @redirect_uri,
          "scope" => @scope,
          "state" => state,
          "show_dialog" => "true"
        })

    IO.puts("\nOpening browser to Spotify authorize URL:")
    IO.puts(url)

    open_browser(url)

    IO.puts("\nWaiting for redirect...")

    receive do
      {:code, code, received_state} ->
        unless received_state == state do
          IO.puts("\nERROR: state mismatch (possible CSRF). Aborting.")
          System.halt(1)
        end

        IO.puts("Got authorization code, exchanging for tokens...")

        case exchange_code(code, client_id, client_secret) do
          {:ok, %{"refresh_token" => refresh, "access_token" => access}} ->
            print_result(client_id, client_secret, refresh, access)
            System.halt(0)

          {:ok, body} ->
            IO.puts("\nERROR: unexpected token response: #{inspect(body)}")
            System.halt(1)

          {:error, reason} ->
            IO.puts("\nERROR: token exchange failed: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, msg} ->
        IO.puts("\nERROR: #{msg}")
        System.halt(1)
    after
      120_000 ->
        IO.puts("\nTimed out waiting for browser redirect after 2 minutes.")
        System.halt(1)
    end
  end

  defp exchange_code(code, client_id, client_secret) do
    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect_uri
      })

    auth = Base.encode64("#{client_id}:#{client_secret}")

    case Req.post(@token_url,
           headers: [
             {"authorization", "Basic #{auth}"},
             {"content-type", "application/x-www-form-urlencoded"}
           ],
           body: body
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp print_result(client_id, client_secret, refresh, access) do
    IO.puts("""

    ============================================================
    SUCCESS! Paste these into .mise.local.toml:

    [env]
    SPOTIFY_CLIENT_ID = "#{client_id}"
    SPOTIFY_CLIENT_SECRET = "#{client_secret}"
    SPOTIFY_REFRESH_TOKEN = "#{refresh}"
    ============================================================

    (access token expires in ~1 hour — the badge will refresh it
     automatically using the refresh token above)

    First 20 chars of access token for sanity:
      #{String.slice(access, 0, 20)}...
    """)
  end

  defp open_browser(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _} -> "xdg-open"
        {:win32, _} -> "start"
      end

    System.cmd(cmd, [url])
  rescue
    _ -> IO.puts("(could not auto-open browser; paste the URL above manually)")
  end

  defp require_env(name) do
    case System.get_env(name) do
      nil ->
        IO.puts("ERROR: environment variable #{name} is not set.")

        IO.puts(
          "Get a client id + secret from https://developer.spotify.com/dashboard\n" <>
            "(redirect URI: http://127.0.0.1:8888/callback)\n\n" <>
            "Then run:\n" <>
            "  SPOTIFY_CLIENT_ID=xxx SPOTIFY_CLIENT_SECRET=yyy elixir scripts/spotify_auth.exs"
        )

        System.halt(1)

      "" ->
        IO.puts("ERROR: environment variable #{name} is empty.")
        System.halt(1)

      value ->
        value
    end
  end
end

defmodule SpotifyAuth.Router do
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/callback"} = conn, _opts) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    parent = Process.whereis(:spotify_auth_parent)

    cond do
      code = params["code"] ->
        send(parent, {:code, code, params["state"]})

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(
          200,
          """
          <!doctype html><meta charset=utf-8>
          <title>Spotify auth complete</title>
          <body style="font-family:system-ui;padding:2em">
          <h1>All good</h1>
          <p>You can close this tab — check the terminal for your tokens.</p>
          </body>
          """
        )

      error = params["error"] ->
        send(parent, {:error, "Spotify returned error: #{error}"})
        send_resp(conn, 400, "Spotify error: #{error} — check terminal.")

      true ->
        send_resp(conn, 400, "Missing code in callback.")
    end
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "Not found")
  end
end

SpotifyAuth.run()
