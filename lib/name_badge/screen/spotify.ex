defmodule NameBadge.Screen.Spotify do
  @moduledoc """
  MusaicFM-style album art screen. Shows one album cover from the user's
  Spotify saved library at a time, cassette-tape spine layout (300×300 art
  on the left, vertical separator, artist + album rotated 90° up the right
  side). Rotates every 5 minutes; button A skips to a new album.

  Covers come pre-downloaded and pre-dithered from `NameBadge.Spotify.ArtCache`,
  so rotation itself never touches the network.
  """

  use NameBadge.Screen

  require Logger

  alias NameBadge.Spotify.{ArtCache, Tokens}

  @rotate_interval :timer.minutes(5)
  @retry_interval :timer.seconds(30)
  @wlan0_present ["interface", "wlan0", "present"]

  @impl NameBadge.Screen
  def mount(_args, screen) do
    timer = Process.send_after(self(), :rotate, 50)
    NameBadge.Network.subscribe(@wlan0_present)

    screen =
      screen
      |> assign(
        image_path: nil,
        artist: nil,
        album: nil,
        status: :loading,
        rotate_timer: timer,
        wifi: NameBadge.Network.wifi_present?()
      )
      |> assign(button_hints: %{a: "New"})
      # 4-level grayscale via the calibrated UC8276 register waveform. Art is
      # pre-dithered to exact {0, 85, 170, 255} values below, so eink's own
      # dithering is disabled — those values map losslessly onto the 4 levels
      # and text edges stay crisp. anti_ghost flushes the panel white before
      # every draw to clear grayscale-mid ghosting from the previous cover.
      |> assign(render_opts: [mode: :grayscale, dither: false, anti_ghost: true])

    {:ok, screen}
  end

  @impl NameBadge.Screen
  def render(%{image_path: path, artist: artist, album: album, wifi: wifi})
      when is_binary(path) do
    compose_png(path, artist, album, wifi)
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

  # The wifi indicator tracks the chip's actual power state; a change
  # re-renders the current cover with the updated icon (assign diffing in
  # NameBadge.Screen skips the redraw when nothing changed).
  def handle_info({VintageNet, @wlan0_present, _old, present, _meta}, screen) do
    {:noreply, assign(screen, wifi: present == true)}
  end

  def handle_info(_msg, screen), do: {:noreply, screen}

  @impl NameBadge.Screen
  def terminate(_reason, screen) do
    cancel_timer(screen)
    cleanup_image(screen.assigns[:image_path])
    NameBadge.Network.wifi_on()
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
    cond do
      not Tokens.configured?() ->
        assign(screen, status: :unauthorized)

      cover = ArtCache.take() ->
        show_cover(screen, cover)

      true ->
        schedule_rotate(screen, @retry_interval)
    end
  end

  defp show_cover(screen, %{png: png, artist: artist, album: album}) do
    path = Path.join(tmp_root(), "album_#{System.unique_integer([:positive])}.png")
    File.write!(path, png)
    cleanup_image(screen.assigns[:image_path])

    screen
    |> assign(image_path: path, artist: artist, album: album, status: :ok)
    |> schedule_rotate(@rotate_interval)
  end

  defp cleanup_image(nil), do: :ok

  defp cleanup_image(path) do
    _ = File.rm(path)
    :ok
  end

  # ---- Typst composition ----

  @doc """
  Renders the cassette-spine layout to a PNG binary: cover art left, vertical
  separator, artist + album rotated up the right side, wifi indicator in the
  bottom-right corner. "Noto Sans JP" only kicks in per-glyph for characters
  Poppins lacks (Japanese titles used to render as tofu boxes).

  Public so `scripts/test_typst_composition.exs` can smoke-test the real
  template on the host.

  @example `Spotify.compose_png(path, "Nirvana", "In Utero", false) // <<PNG>>`
  """
  def compose_png(image_path, artist, album, wifi?) do
    copy_icons()
    filename = Path.basename(image_path)
    wifi_icon = if wifi?, do: "wifi.png", else: "wifi-slash.png"

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

    #place(bottom + right, dx: -6pt, dy: -6pt, image("icons/#{wifi_icon}", width: 12pt))
    """

    typst_opts = [root_dir: tmp_root(), extra_fonts: [fonts_dir()]]

    Typst.render_to_png!(template, [], typst_opts)
    |> List.first()
  end

  defp copy_icons do
    src = Application.app_dir(:name_badge, "priv/typst/images/icons")
    dest = Path.join(tmp_root(), "icons")
    File.mkdir_p!(dest)

    for icon <- ["wifi.png", "wifi-slash.png"] do
      File.cp!(Path.join(src, icon), Path.join(dest, icon))
    end

    :ok
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
