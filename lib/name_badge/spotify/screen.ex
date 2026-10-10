defmodule NameBadge.Spotify.Screen do
  @moduledoc """
  The badge's only screen: one album cover from the user's Spotify saved
  library at a time, MusaicFM style, in a cassette-spine layout (300x300 art
  on the left, a separator, artist and album rotated up the right side).

  Rotates every 5 minutes; button A skips to the next album. Covers come
  pre-downloaded and pre-dithered from `NameBadge.Spotify.ArtCache`, so
  rotation itself never touches the network.
  """

  use GenServer

  require Logger

  alias NameBadge.{Diagnostics, Display}
  alias NameBadge.Spotify.{ArtCache, Tokens}

  @rotate_interval :timer.minutes(5)
  @retry_interval :timer.seconds(30)

  # 4-level grayscale via the calibrated UC8276 waveform. Art is pre-dithered
  # to exact {0, 85, 170, 255} values, so eink's own dithering is off: those
  # map losslessly onto the 4 levels and text edges stay crisp. Add
  # `anti_ghost: true` for a white flush before each draw if covers start
  # leaving visible residue (it was more annoying than the ghosting).
  @draw_opts [mode: :grayscale, dither: false]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl GenServer
  def init(:ok) do
    send(self(), :rotate)
    {:ok, %{timer: nil}}
  end

  @impl GenServer
  def handle_info(:rotate, state) do
    {:noreply, rotate(state)}
  end

  def handle_info(:button_pressed, state) do
    Logger.info("Spotify screen: button A, skipping to the next album")

    state = cancel_timer(state)
    state = rotate(state)
    drop_queued(:button_pressed)

    {:noreply, state}
  end

  # ---- Rotation ----

  defp rotate(state) do
    cond do
      not Tokens.configured?() ->
        Display.render_typst(not_configured_page())
        state

      cover = ArtCache.take() ->
        draw_cover(cover)
        schedule_rotate(state, @rotate_interval)

      true ->
        schedule_rotate(state, @retry_interval)
    end
  end

  defp draw_cover(%{png: png, artist: artist, album: album}) do
    path = Path.join(tmp_root(), "album_#{System.unique_integer([:positive])}.png")
    File.write!(path, png)

    path
    |> compose_png(artist, album)
    |> Display.render_png(@draw_opts)

    File.rm(path)
  end

  defp schedule_rotate(state, delay) do
    %{state | timer: Process.send_after(self(), :rotate, delay)}
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

  defp not_configured_page do
    """
    #set page(width: 400pt, height: 300pt, margin: 32pt)
    #set text(font: "Poppins", size: 14pt)

    #align(center + horizon)[
      #text(size: 24pt, weight: "bold")[Spotify not configured]
      #v(8pt)
      Add the Spotify credentials to .mise.local.toml, then reflash.
    ]
    """
  end

  # ---- Typst composition ----

  # Renders the cassette-spine layout to a PNG binary: cover art left, a
  # separator, artist + album rotated up the right side. "Noto Sans JP" only
  # kicks in per-glyph for characters Poppins lacks (Japanese titles used to
  # render as tofu boxes).
  #
  # compose_png("/tmp/album_1.png", "Nirvana", "In Utero") # <<137, 80, ...>>
  defp compose_png(image_path, artist, album) do
    filename = Path.basename(image_path)

    template = """
    #set page(width: 400pt, height: 300pt, margin: 0pt)
    #set text(font: ("Poppins", "Noto Sans JP"))

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

    Diagnostics.measure(:cover_compose, fn ->
      Typst.render_to_png!(template, [], typst_opts)
      |> List.first()
    end)
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
