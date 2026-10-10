# Spotify Badge Firmware

Elixir/Nerves firmware that turns the Protolux Trellis e-ink badge into a single-purpose Spotify cover display. It boots straight into a [MusaicFM](https://github.com/obrhoff/MusaicFM)-style screen that shows one album from your saved library at a time, in a cassette-spine layout, and rotates every 5 minutes. Button A skips to the next album. That's the whole UI.

Covers are prefetched and dithered in short WiFi bursts, so the radio stays powered off between them and the badge runs for days on battery.

Forked from [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge), the badge firmware handed out at the [Goatmire](https://goatmire.com/) Elixir conference (Gothenburg, 2025).

## Related Repositories

- [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge): upstream firmware (this fork's parent)
- [`protolux-electronics/nerves_system_trellis`](https://github.com/protolux-electronics/nerves_system_trellis): custom Nerves system for the Allwinner T113-S4 SoC
- [`protolux-electronics/wisteria_hardware`](https://github.com/protolux-electronics/wisteria_hardware): hardware design files
- [`gworkman/usb_fel_loaders`](https://github.com/gworkman/usb_fel_loaders): FEL-mode USB recovery toolkit

## Device Architecture

```
┌──────────────────────────────────────────────────┐
│  Elixir application (this repo)                  │  ← you own this
│    Spotify screen · Typst · Dither · EInk SPI    │
│    VintageNet · WiFi power manager               │
├──────────────────────────────────────────────────┤
│  BEAM / OTP 28 / Elixir 1.19                     │
├──────────────────────────────────────────────────┤
│  erlinit (PID 1)                                 │
├──────────────────────────────────────────────────┤
│  nerves_system_trellis  (hex package)            │
│    Buildroot rootfs (squashfs, A/B slots)        │
│    Linux 6.12.32 + sun8i-t113s-trellis.dts       │
│    U-Boot 2025.04 + SPL                          │
├──────────────────────────────────────────────────┤
│  Allwinner T113-S4 SoC  (dual Cortex-A7, ARMv7)  │
│    256 MB DDR3 · eMMC · e-ink 400×300 · WiFi     │
└──────────────────────────────────────────────────┘
```

Layer-by-layer detail lives in [`docs/`](./docs/); see [`CLAUDE.md`](./CLAUDE.md) for the index.

## Usage

Prereqs (macOS): `mise install`, `brew install xz fwup squashfs pkg-config coreutils`, `mix archive.install hex nerves_bootstrap --force`. Spotify credentials go in `.mise.local.toml` (see `scripts/spotify_auth.exs`).

```sh
# Build firmware and flash it to a booted badge at wisteria.local:
./scripts/build.sh && ./scripts/push.sh

# SSH into the badge (IEx prompt, password: nerves):
./scripts/ssh.sh

# First-time flash or brick recovery (USB-FEL, see docs/usb_fel_loaders.md):
./scripts/burn.sh
```

- **`build.sh`**: trellis firmware (runs `mix deps.get` first)
- **`push.sh`**: OTA flash to `wisteria.local` (optional host arg, bails if no `.fw` exists)
- **`burn.sh`**: USB-FEL flash with a pre-flight checklist and an `Enter to continue` gate
- **`ssh.sh`**: SSH to the badge (optional host arg)
- **`clean.sh`**: wipes `_build` + `deps` when a build gets into a bad state

## Credits

Forked from [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) by [Gus Workman](https://github.com/gworkman) / [Protolux Electronics](https://protolux.io). Original hardware and firmware produced for [Goatmire 2025](https://goatmire.com/) thanks to [Lars Wikman](https://github.com/lawik). [Conference talk on YouTube](https://youtu.be/VFmlNZ_BQHQ).
