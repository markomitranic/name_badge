defmodule NameBadge.Screen.Spotify do
  @moduledoc """
  MusaicFM-style album art screen. Shows one album cover from the user's
  Spotify saved library at a time, cassette-tape spine layout (300×300 art
  on the left, vertical separator, artist + album rotated 90° up the right
  side). Rotates every 5 minutes; button A skips to a new album.
  """

  use NameBadge.Screen

  require Logger

  alias NameBadge.Spotify.{Album, Library, Tokens}

  @rotate_interval :timer.minutes(5)
  @retry_interval :timer.seconds(30)
  @image_timeout 10_000

  @impl NameBadge.Screen
  def mount(_args, screen) do
    timer = Process.send_after(self(), :rotate, 50)

    screen =
      screen
      |> assign(
        image_path: nil,
        artist: nil,
        album: nil,
        status: :loading,
        rotate_timer: timer
      )
      |> assign(button_hints: %{a: "New"})

    {:ok, screen}
  end

  @impl NameBadge.Screen
  def render(%{image_path: path, artist: artist, album: album}) when is_binary(path) do
    compose_png(path, artist, album)
  end

  def render(%{status: :unauthorized}) do
    """
    #show heading: set text(font: "Silkscreen", size: 32pt, weight: 400, tracking: -4pt)

    = Spotify

    #v(16pt)

    #align(center + horizon)[
      #text(size: 18pt)[Not configured]
      #v(8pt)
      #text(size: 12pt, fill: gray)[Set SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET,
      and SPOTIFY_REFRESH_TOKEN in .mise.local.toml,]
      #text(size: 12pt, fill: gray)[then reflash.]
    ]
    """
  end

  def render(%{status: :empty_library}) do
    """
    #show heading: set text(font: "Silkscreen", size: 32pt, weight: 400, tracking: -4pt)

    = Spotify

    #v(16pt)

    #align(center + horizon)[
      #text(size: 18pt)[No albums found.]
      #v(4pt)
      #text(size: 12pt, fill: gray)[Save some albums to your Spotify library.]
    ]
    """
  end

  def render(_) do
    """
    #show heading: set text(font: "Silkscreen", size: 32pt, weight: 400, tracking: -4pt)

    = Spotify

    #v(16pt)

    #align(center + horizon)[
      #text(size: 20pt)[Loading...]
    ]
    """
  end

  @impl NameBadge.Screen
  def handle_button(:button_1, :single_press, screen) do
    Logger.info("Spotify screen: button A → immediate rotate")
    screen = cancel_timer(screen)
    screen = do_rotate(screen)
    {:noreply, screen}
  end

  def handle_button(_, _, screen), do: {:noreply, screen}

  @impl NameBadge.Screen
  def handle_info(:rotate, screen) do
    screen = %{screen | assigns: Map.put(screen.assigns, :rotate_timer, nil)}
    screen = do_rotate(screen)
    {:noreply, screen}
  end

  def handle_info(_msg, screen), do: {:noreply, screen}

  @impl NameBadge.Screen
  def terminate(_reason, screen) do
    cancel_timer(screen)
    cleanup_image(screen.assigns[:image_path])
    :ok
  end

  defp cancel_timer(screen) do
    case screen.assigns[:rotate_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    assign(screen, rotate_timer: nil)
  end

  defp schedule_rotate(screen, delay) do
    timer = Process.send_after(self(), :rotate, delay)
    assign(screen, rotate_timer: timer)
  end

  # ---- Rotation ----

  defp do_rotate(screen) do
    if Tokens.configured?() do
      case Library.random_album() do
        %Album{image_url: url} = album when is_binary(url) ->
          case fetch_image(url) do
            {:ok, path} ->
              cleanup_image(screen.assigns[:image_path])

              screen
              |> assign(
                image_path: path,
                artist: album.artist,
                album: album.name,
                status: :ok
              )
              |> schedule_rotate(@rotate_interval)

            {:error, reason} ->
              Logger.warning("Album image fetch failed: #{inspect(reason)}")
              schedule_rotate(screen, @retry_interval)
          end

        _ ->
          screen
          |> assign(status: :empty_library)
          |> schedule_rotate(@retry_interval)
      end
    else
      assign(screen, status: :unauthorized)
    end
  end

  defp fetch_image(url) do
    case Req.get(url, receive_timeout: @image_timeout, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        ext = detect_ext(body)
        path = Path.join(tmp_root(), "album_#{System.unique_integer([:positive])}#{ext}")
        File.write!(path, body)
        {:ok, path}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp detect_ext(<<0xFF, 0xD8, 0xFF, _::binary>>), do: ".jpg"
  defp detect_ext(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: ".png"
  defp detect_ext(_), do: ".bin"

  defp cleanup_image(nil), do: :ok

  defp cleanup_image(path) do
    _ = File.rm(path)
    :ok
  end

  # ---- Typst composition ----

  defp compose_png(image_path, artist, album) do
    filename = Path.basename(image_path)

    template = """
    #set page(width: 400pt, height: 300pt, margin: 0pt)
    #set text(font: "Poppins")

    #grid(
      columns: (300pt, 1pt, 99pt),
      rows: (300pt,),
      image("#{filename}", width: 300pt, height: 300pt, fit: "cover"),
      rect(width: 1pt, height: 300pt, fill: black),
      align(center + horizon, rotate(-90deg, reflow: true,
        box(width: 280pt, inset: (x: 8pt))[
          #align(center, stack(dir: ttb, spacing: 6pt,
            text(size: 20pt, weight: "bold", tracking: 0.5pt)[#{escape(artist)}],
            text(size: 18pt, weight: "semibold", style: "italic", fill: rgb("#333333"))[#{escape(album)}],
          ))
        ]
      ))
    )
    """

    typst_opts = [root_dir: tmp_root(), extra_fonts: [fonts_dir()]]

    Typst.render_to_png!(template, [], typst_opts)
    |> List.first()
  end

  # Escape Typst markup special chars so artist/album text renders as plain
  # text regardless of what Spotify returns.
  defp escape(nil), do: ""

  defp escape(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("#", "\\#")
    |> String.replace("$", "\\$")
    |> String.replace("*", "\\*")
    |> String.replace("_", "\\_")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("<", "\\<")
    |> String.replace(">", "\\>")
    |> String.replace("@", "\\@")
    |> String.replace("=", "\\=")
    |> String.replace("`", "\\`")
    |> String.replace("\"", "\\\"")
  end

  defp tmp_root do
    dir = Path.join(System.tmp_dir!(), "name_badge_spotify")
    File.mkdir_p!(dir)
    dir
  end

  defp fonts_dir, do: Application.app_dir(:name_badge, "priv/typst/fonts")
end
