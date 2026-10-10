#!/usr/bin/env elixir
# Mirrors the Spotify saved-albums library into .spotify/ and renders every
# cover into a finished, display-ready frame for the badge. Runs on the
# laptop; the badge never talks to Spotify.
#
#   mise exec -- elixir scripts/sync.exs                # library + render
#   mise exec -- elixir scripts/sync.exs --render-only  # skip Spotify, render missing frames
#
# 1. Library: fetches every saved album into .spotify/library.json, downloads
#    missing cover originals to .spotify/originals/<id>.jpg, and drops the
#    files of albums that left the library.
# 2. Render: gives every album without one a frame at .spotify/rendered/<id>.png.
#    Changing @recipe in Sync.Frame re-renders the whole library.
#
# Pushing frames to the badge is a separate step: scripts/push_covers.exs.
# Needs SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET and SPOTIFY_REFRESH_TOKEN
# (see scripts/spotify_auth.exs), normally from .mise.local.toml.

Mix.install([
  {:req, "~> 0.5.17"},
  {:typst, "== 0.3.2"},
  {:dither, "== 0.2.4"}
])

defmodule Sync.Paths do
  @moduledoc "Where the mirrored library lives in the repo."

  @root Path.expand("..", __DIR__)

  def library, do: Path.join(@root, ".spotify/library.json")
  def originals, do: Path.join(@root, ".spotify/originals")
  def rendered, do: Path.join(@root, ".spotify/rendered")
  def fonts, do: Path.join(@root, "scripts/fonts")

  def original(id), do: Path.join(originals(), id <> ".jpg")
  def frame(id), do: Path.join(rendered(), id <> ".png")
end

defmodule Sync.Spotify do
  @moduledoc "The two Spotify Web API calls the sync needs."

  @token_url "https://accounts.spotify.com/api/token"
  @albums_url "https://api.spotify.com/v1/me/albums?limit=50"

  @doc """
  Exchanges the long-lived refresh token for a short-lived access token.

  @example `Sync.Spotify.access_token() // "BQD..."`
  """
  def access_token do
    auth = Base.encode64(env!("SPOTIFY_CLIENT_ID") <> ":" <> env!("SPOTIFY_CLIENT_SECRET"))

    body =
      Req.post!(@token_url,
        headers: [authorization: "Basic " <> auth],
        form: [grant_type: "refresh_token", refresh_token: env!("SPOTIFY_REFRESH_TOKEN")]
      ).body

    if body["refresh_token"] do
      IO.puts(
        "Spotify rotated the refresh token. Update SPOTIFY_REFRESH_TOKEN to:\n  #{body["refresh_token"]}"
      )
    end

    body["access_token"] ||
      raise "Spotify refused the refresh token (#{body["error_description"] || body["error"]}). " <>
              "Run scripts/spotify_auth.exs again and update .mise.local.toml"
  end

  @doc """
  Every saved album, newest first, as plain maps. Albums without art are skipped.

  @example `Sync.Spotify.saved_albums(token) // [%{"id" => "4LH4d3cOWNNsVw41Gqt2kv", ...}]`
  """
  def saved_albums(token) do
    @albums_url
    |> Stream.unfold(fn
      nil -> nil
      url -> next_page(url, token)
    end)
    |> Enum.flat_map(& &1)
    |> Enum.flat_map(&to_album/1)
  end

  defp next_page(url, token) do
    body = Req.get!(url, auth: {:bearer, token}).body

    IO.write(
      "\r  fetched #{min(body["offset"] + body["limit"], body["total"])}/#{body["total"]} albums"
    )

    if body["next"] == nil, do: IO.puts("")

    {body["items"], body["next"]}
  end

  defp to_album(%{"added_at" => added_at, "album" => album}) do
    case Enum.max_by(album["images"], & &1["width"], fn -> nil end) do
      nil ->
        []

      image ->
        artist = Enum.map_join(album["artists"], ", ", & &1["name"])

        [
          %{
            "id" => album["id"],
            "artist" => artist,
            "album" => album["name"],
            "added_at" => added_at,
            "image" => image["url"]
          }
        ]
    end
  end

  defp env!(name) do
    System.get_env(name) || raise "#{name} is not set (see scripts/spotify_auth.exs)"
  end
end

defmodule Sync.Library do
  @moduledoc "Phase 1: the manifest plus one original cover per album."

  alias Sync.{Paths, Spotify}

  @doc """
  Mirrors the Spotify library to disk and returns the albums.

  @example `Sync.Library.sync() // [%{"id" => ..., "artist" => ..., ...}]`
  """
  def sync do
    IO.puts("Library")
    albums = Spotify.access_token() |> Spotify.saved_albums()

    write_manifest(albums)
    prune(albums)
    download_missing(albums)

    albums
  end

  @doc """
  The albums from the last sync, without touching the network.

  @example `Sync.Library.load() // [%{"id" => ..., ...}]`
  """
  def load do
    Paths.library() |> File.read!() |> JSON.decode!()
  end

  # One album per line keeps git diffs readable when the library changes.
  defp write_manifest(albums) do
    lines = Enum.map_join(albums, ",\n", &JSON.encode!/1)
    File.mkdir_p!(Path.dirname(Paths.library()))
    File.write!(Paths.library(), "[\n" <> lines <> "\n]\n")
  end

  defp prune(albums) do
    ids = MapSet.new(albums, & &1["id"])

    removed =
      for dir <- [Paths.originals(), Paths.rendered()],
          File.dir?(dir),
          file <- File.ls!(dir),
          not MapSet.member?(ids, Path.rootname(file)),
          not String.starts_with?(file, ".") do
        File.rm!(Path.join(dir, file))
      end

    if removed != [], do: IO.puts("  removed #{length(removed)} files of albums no longer saved")
  end

  defp download_missing(albums) do
    File.mkdir_p!(Paths.originals())
    missing = Enum.reject(albums, &File.exists?(Paths.original(&1["id"])))

    missing
    |> Task.async_stream(&download/1, max_concurrency: 8, timeout: :infinity)
    |> Stream.with_index(1)
    |> Enum.each(fn {_, n} -> IO.write("\r  downloaded #{n}/#{length(missing)} new covers") end)

    if missing != [], do: IO.puts("")
    IO.puts("  #{length(albums)} albums, #{length(missing)} new")
  end

  defp download(album) do
    jpeg = Req.get!(album["image"], decode_body: false).body
    File.write!(Paths.original(album["id"]) <> ".part", jpeg)
    File.rename!(Paths.original(album["id"]) <> ".part", Paths.original(album["id"]))
  end
end

defmodule Sync.Frame do
  @moduledoc """
  Renders one album into a finished 400x300 frame: the cover dithered to the
  panel's four gray levels on the left, a separator, and artist + album
  rotated up a spine on the right.

  Every pixel of the output is exactly 0, 85, 170 or 255, the four levels the
  badge's calibrated grayscale waveform draws, so the badge only decodes and
  draws it.
  """

  @art_size 300

  # Each panel gray as linear-light reflectance => the level the badge draws it
  # from. The calibrated waveform shows 85 at 9.1% and 170 at 45.7% of white.
  @panel_grays %{0 => 0, 23 => 85, 117 => 170, 255 => 255}

  # Bumping any value here re-renders the whole library on the next sync.
  @recipe %{
    layout: 1,
    art_size: @art_size,
    contrast_clip: {0.01, 0.99},
    gamma: 2.2,
    panel_grays: @panel_grays,
    algorithm: :stucki
  }

  def recipe, do: @recipe

  @doc """
  Renders an album's frame as PNG bytes.

  @example `Sync.Frame.render(%{"id" => "4LH4", "artist" => "Nirvana", "album" => "In Utero"}, workdir) // <<137, 80, ...>>`
  """
  def render(album, workdir) do
    art_file = album["id"] <> ".png"
    art_path = Path.join(workdir, art_file)

    album["id"]
    |> Sync.Paths.original()
    |> File.read!()
    |> dithered_art()
    |> then(&File.write!(art_path, &1))

    try do
      art_file
      |> spine_template(album["artist"], album["album"])
      |> Typst.render_to_png!([], root_dir: workdir, extra_fonts: [Sync.Paths.fonts()])
      |> hd()
      |> snap_to_levels()
    after
      File.rm(art_path)
    end
  end

  # Grayscale at the exact slot size (no second resample inside Typst), a
  # contrast stretch so dark covers don't dither to a flat grey, then error
  # diffusion in linear light against what the panel really reflects, so
  # midtones and shadows keep the brightness the eye expects.
  defp dithered_art(jpeg) do
    {low, high} = @recipe.contrast_clip
    palette = for {linear, _level} <- @panel_grays, do: {linear, linear, linear}

    jpeg
    |> Dither.decode!()
    |> Dither.resize!(@art_size, @art_size)
    |> Dither.grayscale!()
    |> Dither.to_raw!()
    |> stretch_contrast(low, high)
    |> to_linear_light()
    |> Dither.from_raw!(@art_size, @art_size)
    |> Dither.dither!(algorithm: @recipe.algorithm, palette: palette)
    |> Dither.grayscale!()
    |> Dither.to_raw!()
    |> to_panel_levels()
    |> Dither.from_raw!(@art_size, @art_size)
    |> Dither.encode!()
  end

  defp to_linear_light(raw) do
    for <<b <- raw>>, into: <<>>, do: <<round(255 * :math.pow(b / 255, @recipe.gamma))>>
  end

  defp to_panel_levels(raw) do
    for <<b <- raw>>, into: <<>>, do: <<Map.fetch!(@panel_grays, b)>>
  end

  # Linearly rescales so the low/high percentile pixels become black/white;
  # the clip keeps a few outliers from cancelling the stretch.
  defp stretch_contrast(raw, low, high) do
    sorted = raw |> :binary.bin_to_list() |> Enum.sort() |> List.to_tuple()
    lo = elem(sorted, trunc(tuple_size(sorted) * low))
    hi = elem(sorted, trunc(tuple_size(sorted) * high) - 1)
    range = max(hi - lo, 1)

    for <<b <- raw>>, into: <<>>, do: <<trunc((min(max(b, lo), hi) - lo) * 255 / range)>>
  end

  # Antialiased spine text lands between levels; snap it with the same
  # thresholds the badge's eink driver uses, so text edges stay crisp.
  defp snap_to_levels(png) do
    image = png |> Dither.decode!() |> Dither.grayscale!()
    %{size: {width, height}} = image

    snapped =
      for <<b <- Dither.to_raw!(image)>>, into: <<>> do
        cond do
          b >= 213 -> <<255>>
          b >= 128 -> <<170>>
          b >= 42 -> <<85>>
          true -> <<0>>
        end
      end

    snapped |> Dither.from_raw!(width, height) |> Dither.encode!()
  end

  # "Noto Sans JP" only kicks in per-glyph for characters Poppins lacks.
  defp spine_template(art_file, artist, album) do
    """
    #set page(width: 400pt, height: 300pt, margin: 0pt)
    #set text(font: ("Poppins", "Noto Sans JP"))

    #grid(
      columns: (300pt, 1pt, 99pt),
      rows: (300pt,),
      image("#{art_file}", width: 300pt, height: 300pt, fit: "cover"),
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
  end

  # Typst markup characters in titles must render as plain text.
  defp escape(text) do
    String.replace(text, ~w(\\ # $ * _ [ ] < > @ = ` "), &("\\" <> &1))
  end
end

defmodule Sync.Render do
  @moduledoc "Phase 2: a frame for every album that doesn't have one yet."

  alias Sync.{Frame, Paths}

  @doc """
  Renders missing frames, re-rendering everything when the recipe changed.

  @example `Sync.Render.run(albums) // :ok`
  """
  def run(albums) do
    IO.puts("Render")
    File.mkdir_p!(Paths.rendered())
    discard_if_recipe_changed()

    missing = Enum.reject(albums, &File.exists?(Paths.frame(&1["id"])))
    workdir = Path.join(System.tmp_dir!(), "spotify_badge_render")
    File.mkdir_p!(workdir)

    missing
    |> Task.async_stream(&render_one(&1, workdir), timeout: :infinity, ordered: false)
    |> Stream.with_index(1)
    |> Enum.each(fn {_, n} -> IO.write("\r  rendered #{n}/#{length(missing)}") end)

    if missing != [], do: IO.puts("")
    IO.puts("  #{length(albums) - length(missing)} up to date, #{length(missing)} rendered")
  end

  defp render_one(album, workdir) do
    png = Frame.render(album, workdir)
    File.write!(Paths.frame(album["id"]) <> ".part", png)
    File.rename!(Paths.frame(album["id"]) <> ".part", Paths.frame(album["id"]))
  end

  defp discard_if_recipe_changed do
    recipe_file = Path.join(Paths.rendered(), ".recipe")
    recipe = inspect(Frame.recipe())

    if File.read(recipe_file) != {:ok, recipe} do
      stale = Path.wildcard(Path.join(Paths.rendered(), "*.png"))
      Enum.each(stale, &File.rm!/1)

      if stale != [],
        do: IO.puts("  render recipe changed, re-rendering all #{length(stale)} frames")

      File.write!(recipe_file, recipe)
    end
  end
end

albums =
  case System.argv() do
    ["--render-only"] -> Sync.Library.load()
    [] -> Sync.Library.sync()
  end

Sync.Render.run(albums)
