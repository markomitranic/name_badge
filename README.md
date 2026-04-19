# Trellis Badge Firmware

Elixir/Nerves application for the Protolux Trellis e-ink badges distributed at the [Goatmire](https://goatmire.com/) Elixir conference (Gothenburg, September 2025). Forked from [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) as a starting point for independent development.

## Related Repositories

- [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) — upstream firmware (this fork's parent)
- [`protolux-electronics/nerves_system_trellis`](https://github.com/protolux-electronics/nerves_system_trellis) — custom Nerves system for the Allwinner T113-S4 SoC
- [`protolux-electronics/goatmire`](https://github.com/protolux-electronics/goatmire) — Phoenix cloud app (optional: gallery, config push, survey)
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

```sh
mix deps.get                                                    # fetch deps
mix firmware                                                    # build .fw
cat _build/trellis_dev/nerves/images/name_badge.fw \
  | ssh -s nerves@wisteria.local fwup                           # flash over SSH
ssh nerves@wisteria.local                                       # IEx (password: nerves)
```

Simulator: `MIX_TARGET=host iex -S mix` → <http://localhost:4000>

First-time flash or brick recovery: see [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md).

## Credits

Forked from [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge) by [Gus Workman](https://github.com/gworkman) / [Protolux Electronics](https://protolux.io). Original hardware and firmware produced for [Goatmire 2025](https://goatmire.com/) thanks to [Lars Wikman](https://github.com/lawik). Notable upstream contributions: [Matthias Männich](https://github.com/matthias-maennich) (LiveView simulator), [Peter Ullrich](https://github.com/pxp9) (snake, weather, calendar). [Conference talk on YouTube](https://youtu.be/VFmlNZ_BQHQ).
