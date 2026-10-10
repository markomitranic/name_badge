defmodule NameBadge.Spotify.Art do
  @moduledoc """
  Downloads an album cover and preprocesses it into a display-ready PNG.

  Art is rendered into a 300x300 pt slot in the Typst template, which at
  Typst's default 72dpi is 300x300 px. Pre-resizing to exactly that avoids
  a second resample inside Typst that would blur the dithered pattern.

  The image is dithered to 2 bits (4 gray levels) with error diffusion, so
  the resulting pixels are exactly {0, 85, 170, 255} — the grayscale draw
  path maps them 1:1 onto the panel's 4 calibrated levels.
  """

  alias NameBadge.Diagnostics

  @art_size 300

  # Stucki preserves mid-tone structure with less granular noise than
  # Floyd-Steinberg — good for album art on this panel. Swap to
  # :atkinson / :floyd_steinberg / :sierra / :stucki / :burkes / :jarvis to taste.
  @dither_algorithm :stucki

  @image_timeout 10_000

  @doc """
  Downloads the cover at `url` and returns `{:ok, png_binary}` ready for
  the display, or `{:error, reason}`.

  @example `Art.fetch("https://i.scdn.co/image/...") // {:ok, <<137, 80, ...>>}`
  """
  def fetch(url) do
    download = fn -> Req.get(url, receive_timeout: @image_timeout, decode_body: false) end

    case Diagnostics.measure(:cover_download, download) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Diagnostics.measure(:cover_dither, fn -> preprocess(body) end)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Resize to the exact display slot, stretch the histogram so dark covers
  # don't dither to a flat grey, then run error-diffusion dithering.
  defp preprocess(body) do
    try do
      image =
        body
        |> Dither.decode!()
        |> Dither.resize!(@art_size, @art_size)
        |> Dither.grayscale!()

      raw =
        image
        |> Dither.to_raw!()
        |> stretch_contrast()

      png =
        raw
        |> Dither.from_raw!(@art_size, @art_size)
        |> Dither.dither!(algorithm: @dither_algorithm, bit_depth: 2)
        |> Dither.encode!()

      {:ok, png}
    rescue
      e -> {:error, e}
    end
  end

  # Linearly rescale grayscale bytes so the darkest pixel maps to 0 and the
  # brightest to 255. A tiny percentile clip keeps outlier pixels from
  # suppressing the stretch on nearly-monochrome covers.
  defp stretch_contrast(raw) when is_binary(raw) do
    {lo, hi} = percentile_bounds(raw, 0.01, 0.99)
    range = max(hi - lo, 1)

    for <<b <- raw>>, into: <<>> do
      scaled = trunc((max(min(b, hi), lo) - lo) * 255 / range)
      <<scaled>>
    end
  end

  defp percentile_bounds(raw, low_p, high_p) do
    histogram =
      Enum.reduce(0..255, %{}, fn v, acc -> Map.put(acc, v, 0) end)

    histogram =
      for <<b <- raw>>, reduce: histogram do
        acc -> Map.update!(acc, b, &(&1 + 1))
      end

    total = byte_size(raw)
    low_target = trunc(total * low_p)
    high_target = trunc(total * high_p)

    {lo, hi, _} =
      Enum.reduce(0..255, {0, 255, 0}, fn v, {lo, hi, cum} ->
        cum = cum + Map.get(histogram, v, 0)
        lo = if cum <= low_target, do: v, else: lo
        hi = if cum <= high_target, do: v, else: hi
        {lo, hi, cum}
      end)

    {lo, hi}
  end
end
