defmodule NameBadge.GrayTune do
  @moduledoc """
  Live tuning harness for the UC8276 4-level grayscale waveform.

  The Goatmire panel has no factory grayscale LUT, so `mode: :grayscale` only
  produces 2 tones. This lets us hand-author a grayscale init + LUT and see the
  result on-device in ~1 second, straight from IEx — no `mix firmware` per tweak.

  It drives the panel via `EInk.gc4_tune/4`, which runs inside the EInk
  GenServer (so it can't collide with normal screen draws).

  ## Usage on the badge

      iex> alias NameBadge.GrayTune
      iex> GrayTune.run()                          # current preset, 4-band test image
      iex> GrayTune.run(GrayTune.gradient())       # smooth gradient instead
      iex> GrayTune.run(GrayTune.bands(), init: my_init, lut: my_lut)  # your own values
      iex> GrayTune.probe(3, 8)                    # anchored probe for photo measurement

  The goal: four clearly distinct vertical bands (black | dark gray | light gray
  | white). Tweak `init/0` and `lut/0` below, or pass `:init`/`:lut` inline, and
  re-run until the middle two bands separate cleanly.
  """

  import Bitwise

  @w 400
  @h 300

  @doc """
  Push init + LUT and draw a test image (default: the 4-band bar).

  Opts:
    * `:init` / `:lut` — replace the presets wholesale with your own lists.
    * `:patch` — `[{reg, binary}]` overrides merged onto the init preset, for
      one-line voltage/timing tweaks, e.g. `patch: [{0x82, <<0x1C>>}]`.
    * `:swap_grays` — `true` swaps the two mid-gray LUTs (0x22 ↔ 0x23) if light
      and dark come out reversed.

  ## Examples

      GrayTune.run()                                    # seed waveform, bands
      GrayTune.run(GrayTune.gradient())                 # gradient
      GrayTune.run(GrayTune.bands(), patch: [{0x82, <<0x1C>>}])   # nudge VCOM
      GrayTune.run(GrayTune.bands(), swap_grays: true)  # flip mid grays
  """
  def run(image \\ bands(), opts \\ []) do
    init = opts |> Keyword.get(:init, init()) |> patch(Keyword.get(opts, :patch, []))

    lut =
      opts
      |> Keyword.get(:lut, lut())
      |> maybe_swap_grays(Keyword.get(opts, :swap_grays, false))

    {s10, s13} = EInk.Utils.pack_grayscale(image)

    # gc4_tune lives only in the local ../eink calibration rig (stashed on
    # feat/drawing-pipeline), not in the published package — see mix.exs.
    unless function_exported?(EInk, :gc4_tune, 4) do
      raise """
      EInk.gc4_tune/4 is not available in this eink build. To live-tune, point
      mix.exs at the local clone ({:eink, path: "../eink", ...}) and restore
      the tuning scaffolding: git checkout feat/drawing-pipeline && git stash pop
      """
    end

    apply(EInk, :gc4_tune, [init, lut, s10, s13])
  end

  # Replace matching {reg, _} entries in-place, preserving order.
  defp patch(cmds, overrides) do
    Enum.reduce(overrides, cmds, fn {reg, data}, acc ->
      List.keyreplace(acc, reg, 0, {reg, data})
    end)
  end

  defp maybe_swap_grays(lut, false), do: lut

  defp maybe_swap_grays(lut, true) do
    {_, d22} = List.keyfind(lut, 0x22, 0)
    {_, d23} = List.keyfind(lut, 0x23, 0)
    lut |> List.keyreplace(0x22, 0, {0x22, d23}) |> List.keyreplace(0x23, 0, {0x23, d22})
  end

  @doc """
  Calibration probe: bands with fixed black/white anchors and two mid counts.

  Draws `black(0) | probe a | probe b | white(54)` — every photo of the panel
  then carries its own black + white reference, so measurements can be
  normalized regardless of lighting or camera exposure. Counts are on the
  150Hz scale (see `init/0`).

      GrayTune.probe(5, 10)   # measure white-push counts 5 and 10
  """
  def probe(a, b, opts \\ []) do
    run(bands(), Keyword.put(opts, :lut, build_lut([0, a, b, 54], 63)))
  end

  @doc "4 vertical bands, left→right: black | dark gray | light gray | white."
  def bands do
    levels = [0, 85, 170, 255]
    row = for x <- 0..(@w - 1), into: <<>>, do: <<Enum.at(levels, div(x, 100))>>
    :binary.copy(row, @h)
  end

  @doc "Smooth left→right 0..255 gradient — good for spotting banding/ghosting."
  def gradient do
    row = for x <- 0..(@w - 1), into: <<>>, do: <<trunc(x * 255 / (@w - 1))>>
    :binary.copy(row, @h)
  end

  @doc "Decode a real PNG (album art etc.) to a 400x300 grayscale test image."
  def png(path) do
    File.read!(path)
    |> Dither.decode!()
    |> Dither.resize!(@w, @h)
    |> Dither.grayscale!()
    |> Dither.dither!(algorithm: :stucki, bit_depth: 2)
    |> Dither.to_raw!()
  end

  # ── Candidate waveform ─────────────────────────────────────────────────────
  # EDIT THESE. Filled from research on the TWE0420NQN30 / UC8276 4-gray demo.
  # Reg reference: 0x00 PSR (panel setting — grayscale bit lives here),
  # 0x01 power, 0x06 booster, 0x30 PLL/frame-rate, 0x50 VCOM/interval,
  # 0x20 VCOM-LUT (LUTC), 0x21..0x24 transition LUTs.

  @doc """
  Grayscale init — the badge's own proven full-refresh init sequence.

  We deliberately reuse the exact PSR/power/booster/PLL/VCOM values the panel
  already uses for fast 1-bit refresh (0x30 = 0x09 frame rate), so grayscale
  refreshes in seconds too. Only the LUTs (below) differ from 1-bit — they add
  the two intermediate levels. Tuning levers: 0x01 (VSH/VSL magnitude → gray
  spread), 0x82 (VCOM_DC), 0x30 (frame rate).
  """
  def init do
    [
      {0x00, <<0x3F, 0x4D>>},
      {0x01, <<0x03, 0x10, 0x3F, 0x3F, 0x03>>},
      {0x06, <<0x96, 0x96, 0x29>>},
      # 150Hz frame rate (1-bit init uses 0x09 = 50Hz). Each LUT frame delivers
      # 1/3 the dose, so gray placement gets 3x finer without changing total
      # refresh time. All frame counts below are on the 150Hz scale.
      {0x30, <<0x1A>>},
      {0x61, <<0x01, 0x90, 0x01, 0x2C>>},
      {0x82, <<0x05>>},
      {0x50, <<0x97>>},
      {0x60, <<0x22>>},
      {0xE3, <<0x88>>},
      {0x41, <<0x00>>}
    ]
  end

  # Level-select nibble (top 2 bits of a phase byte). The UC8276 datasheet
  # labels these 00=GND, 01=VSH, 10=VSL, 11=VDHR for source LUTs 0x21–0x24,
  # but the observed effect on this panel is: 0x40 drives toward BLACK,
  # 0x80 drives toward WHITE.
  @to_black 0x40
  @to_white 0x80
  # Note on the fourth level select, 0xC0 = VDHR ("red" rail): the datasheet
  # shows it is POSITIVE (2.4–15V, init 0x01 byte 5) — same polarity as VSH,
  # so it can only drive toward BLACK, gently. A soft *whiten* is impossible
  # (confirmed on-device: soft-whitened bands stay black). If finer mid-gray
  # control is ever needed, the scheme must flip to whiten-reset + VDHR
  # soft-blacken. The 150Hz frame rate made that unnecessary here.
  @gnd 0x00

  @doc """
  4-level grayscale LUT in UC8276-native 7-byte-group format.

  Scheme (per pixel): **drive to black (`reset` frames), then whiten for N
  frames.** N=0 stays black; at 150Hz the drive saturates to full white around
  N=50. (Polarity is empirical — the datasheet-derived guess was mirrored on
  this panel: level 01/VSH blackens, 10/VSL whitens.)

  Defaults to `build_lut([0, 5, 10, 54], 63)` — photo-calibrated 2026-07-15
  against sRGB-85/170 reflectance targets (9.1% / 45.7% of panel white,
  measured via camera with in-frame black/white anchors and a screen-photo
  bias correction). Register→pixel mapping (empirical, via the bitplane
  packer): 0x21←black, 0x22←dark gray, 0x23←light gray, 0x24←white.
  """
  def lut, do: build_lut([0, 5, 10, 54], 63)

  @doc """
  Build the 5 LUT registers from four white-push frame counts:
  `[black, dark_gray, light_gray, white]`. Each pixel is first driven to black
  (`reset` frames), then whitened by its count — so 0 = black, ~18 = white.

  The response is non-linear (fast at first, then saturating) and scales with
  the frame rate (0x30): tripling the rate (50→150Hz) shortens each frame to
  1/3, so every count moves the pixel 1/3 as far — `reset` and the white count
  must scale along with the mids. Measured curve at 150Hz (camera-measured
  reflectance, 2026-07):
  N=3→1.3%, 4→3.5%, 5→7.4%, 9→27.8%, 11→57.9%, 13→71.9%.

      GrayTune.run(GrayTune.bands(), lut: GrayTune.build_lut([0, 5, 10, 54], 63))
  """
  def build_lut(white_pushes, reset \\ 63)

  def build_lut([pb, pd, pl, pw], reset) do
    pad = :binary.copy(<<0x00>>, 35)
    settle = 0x02
    maxp = Enum.max([pb, pd, pl, pw])

    # VCOM held at DC (level 00) across the whole drive.
    vcom = group(reset, settle, maxp) <> pad
    mk = fn white when white in 0..63 -> group(@to_black ||| reset, settle, @to_white ||| white) <> pad end

    [
      {0x20, vcom},
      {0x21, mk.(pb)},
      {0x22, mk.(pd)},
      {0x23, mk.(pl)},
      {0x24, mk.(pw)}
    ]
  end

  # One UC8276 LUT group: repeat=1, phase1 (drive black), settle (GND), phase2
  # (drive white), unused phase, state1 repeat=1, state2 repeat=1.
  defp group(phase1, settle, phase2) do
    <<0x01, phase1, settle, phase2, @gnd, 0x01, 0x01>>
  end
end
