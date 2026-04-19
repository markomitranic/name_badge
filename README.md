# Trellis Badge Firmware

Personal Elixir/Nerves playground for the Protolux Trellis e-ink badge, forked from [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) (originally distributed at the [Goatmire](https://goatmire.com/) Elixir conference, Gothenburg 2025). The conference-specific screens (name badge personalization via QR, gallery push from the Goatmire backend, calendar, snake, tutorial) have been stripped out — this fork boots straight into a Weather screen, with a minimal Settings menu (WiFi + System Info) and an optional Spotify album art screen (a [MusaicFM](https://github.com/obrhoff/MusaicFM) port that rotates saved-album covers in a cassette-spine layout). New screens get added here over time.

## Related Repositories

- [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) — upstream firmware (this fork's parent)
- [`protolux-electronics/nerves_system_trellis`](https://github.com/protolux-electronics/nerves_system_trellis) — custom Nerves system for the Allwinner T113-S4 SoC
- [`protolux-electronics/wisteria_hardware`](https://github.com/protolux-electronics/wisteria_hardware) — hardware design files
- [`gworkman/usb_fel_loaders`](https://github.com/gworkman/usb_fel_loaders) — FEL-mode USB recovery toolkit

## Device Architecture

```
┌──────────────────────────────────────────────────┐
│  Elixir application (this repo)                  │  ← you own this
│    screens · Typst · Dither · EInk SPI driver    │
│    VintageNet · NervesHub · /data/config.json    │
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

Prereqs (macOS): `mise install`, `brew install xz fwup squashfs`, `mix archive.install hex nerves_bootstrap --force`.

Everyday workflows live in [`scripts/`](./scripts/):

```sh
# Local browser dev (simulator at http://localhost:4000):
./scripts/clean.sh && ./scripts/dev.sh

# Device dev (build for trellis, flash to a booted badge at wisteria.local):
./scripts/clean.sh && ./scripts/build.sh && ./scripts/push.sh

# SSH into the badge (IEx prompt, password: nerves):
./scripts/ssh.sh

# First-time flash or brick recovery (USB-FEL, see docs/usb_fel_loaders.md):
./scripts/burn.sh
```

What each script does:

- **`dev.sh`** — host simulator (runs `mix deps.get` first)
- **`build.sh`** — trellis firmware (runs `mix deps.get` first)
- **`push.sh`** — OTA flash to `wisteria.local` (takes optional host arg, bails if no `.fw` exists)
- **`burn.sh`** — USB-FEL flash with a full pre-flight checklist and an `Enter to continue` gate before it does anything
- **`ssh.sh`** — SSH to the badge (takes optional host arg)
- **`clean.sh`** — wipes `_build` + `deps` only (deps.get is deferred to the next dev/build so `MIX_TARGET` is set correctly)

`clean.sh` is only strictly needed when switching `MIX_TARGET` between `host` and `trellis`, but including it in the chain is the safe default. Subsequent iterations within the same mode can skip it.

## Credits

Forked from [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) by [Gus Workman](https://github.com/gworkman) / [Protolux Electronics](https://protolux.io). Original hardware and firmware produced for [Goatmire 2025](https://goatmire.com/) thanks to [Lars Wikman](https://github.com/lawik). Notable upstream contributions: [Matthias Männich](https://github.com/matthias-maennich) (LiveView simulator), [Peter Ullrich](https://github.com/pxp9) (weather, and the now-removed snake/calendar screens). [Conference talk on YouTube](https://youtu.be/VFmlNZ_BQHQ).
