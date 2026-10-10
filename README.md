# Spotify Badge

A single-purpose e-ink device: it shows one album from your Spotify saved library at a time, in a cassette-spine layout, and swaps to another every 5 minutes. Press button A to skip. That's the whole interface.

It runs on the Protolux Trellis badge (400×300 e-ink, dual Cortex-A7, WiFi, Li-ion cell) as Elixir/Nerves firmware, and is built to sit on a desk or shelf for days on battery.

## How it works

```
 boot ──▶ Spotify.Screen ──take──▶ ArtCache ──(< 3 left)──▶ refill burst
              │    ▲                 /data/spotify_art         │
              │    └── button A      10 dithered covers        ├─ WiFi on
              ▼                                                ├─ Spotify API: random saved albums
           Display ──▶ e-ink                                   ├─ download, resize, 4-level dither
       (4-level grayscale)                                     └─ WiFi off
```

- **Covers are prepared ahead of time.** A disk-backed queue holds up to 10 covers, already resized and dithered to the panel's four gray levels. Rotating or skipping never touches the network.
- **WiFi is off almost all the time.** When the queue runs low, a ~20 s burst powers the radio up, fetches a fresh batch, and cuts power again at the GPIO. Between bursts the chip is fully off.
- **Random, not sequential.** Each cover is one random offset into your saved albums, so each cover costs one small API call no matter how big the library is (the library size is cached for a day).
- **Nothing to configure on the device.** No menus, no splash, no status bar. It boots straight into the last cover and picks up where it left off.

## Battery

Measured on this badge (Oct 2026):

| Mode | Runtime |
|---|---|
| WiFi on continuously | 6-7 h |
| Normal use (covers rotating, WiFi off between bursts) | days (one run: 4.5 days of uptime before the cell gave out) |

The WiFi chip's power-on surge can brown the board out on a weak cell, so below ~35% (3.65 V) the badge stops refilling: it keeps rotating cached covers, then holds the last one. On USB power WiFi stays on, so the badge is reachable over SSH while plugged in.

## Setup

**Toolchain (macOS):**

```sh
mise install                                            # Elixir 1.19.5 / OTP 28.3
brew install xz fwup squashfs pkg-config coreutils
mix local.hex --force && mix local.rebar --force
mix archive.install hex nerves_bootstrap --force
```

**Spotify credentials:** register an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) with redirect URI `http://127.0.0.1:8888/callback`, then:

```sh
SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=... elixir scripts/spotify_auth.exs
```

Paste the three printed variables into `.mise.local.toml` (git-ignored) under `[env]`. They're compiled into the firmware.

**WiFi** is set once on the device and persists across reboots and reflashes:

```sh
./scripts/ssh.sh   # password: nerves (works over the USB cable without WiFi)
```
```elixir
VintageNetWiFi.quick_configure("ssid", "password")
```

The chip is 2.4 GHz only.

## Build and flash

```sh
./scripts/build.sh && ./scripts/push.sh   # build, then flash a running badge at wisteria.local
./scripts/burn.sh                         # first-time flash or brick recovery over USB-FEL
```

| Script | Does |
|---|---|
| `build.sh` | `mix deps.get` + `mix firmware` for the trellis target |
| `push.sh` | OTA flash over SSH (optional host arg) |
| `burn.sh` | USB-FEL flash, with a pre-flight checklist ([`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md)) |
| `ssh.sh` | IEx prompt on the badge (optional host arg) |
| `clean.sh` | Wipe `_build` + `deps` when a build gets into a bad state |
| `spotify_auth.exs` | One-time Spotify OAuth to get a refresh token |

Keep the badge on USB power while flashing. The reboot after a flash takes 2-3 minutes.

## On the badge

```elixir
NameBadge.Battery.percentage()    # 0-100, along a measured discharge curve
NameBadge.Battery.voltage()       # > 4.5 means USB power
NameBadge.Network.wifi_present?() # is the chip powered right now
send(NameBadge.Spotify.Screen, :button_pressed)  # skip, same as button A
```

Crash monitoring (disk log, boot markers, minute health samples) is built in but off; [`CLAUDE.md`](./CLAUDE.md#monitoring-off-by-default) explains how to switch it on.

## Hardware and lower layers

The firmware sits on the [`nerves_system_trellis`](https://github.com/protolux-electronics/nerves_system_trellis) Nerves system (Buildroot, Linux 6.12, U-Boot, A/B firmware slots) for the Allwinner T113-S4 SoC. [`docs/`](./docs/) has layer-by-layer reference material: bootloader, kernel and device tree, the Nerves system, and FEL recovery.

## Lineage

Started as a fork of [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge), the conference badge firmware by [Gus Workman](https://github.com/gworkman) / [Protolux Electronics](https://protolux.io), made for [Goatmire 2025](https://goatmire.com/) thanks to [Lars Wikman](https://github.com/lawik) ([talk](https://youtu.be/VFmlNZ_BQHQ)). It has since been rewritten into a different device and no longer tracks upstream. The cover layout is a port of [MusaicFM](https://github.com/obrhoff/MusaicFM).
