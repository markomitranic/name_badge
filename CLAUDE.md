# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository is a fork of [`protolux-electronics/name_badge`](https://github.com/protolux-electronics/name_badge), the Elixir/Nerves firmware for the Protolux Trellis e-ink badge distributed at the Goatmire Elixir conference (Gothenburg, September 2025). The owner (Marko) received a badge at the conference.

**It is now a single-purpose Spotify badge (2026-10-10).** It boots straight into the Spotify album art screen; there are no menus, settings, splash screen, status bar or host simulator. Button A skips to the next album, button B does nothing. The goal is stability and battery life: anything that doesn't serve the cover rotation was removed (git history has it: the multi-screen `Screen`/`ScreenManager` framework, `Layout` status bar, Settings → WiFi wizard + System Info, `TimezoneService`/tzdata, NervesHub link, `GrayTune` calibration harness, the LiveView simulator and mocks, power measurement scripts). Monitoring (`NameBadge.Diagnostics`) is kept but switched off.

Supervision tree (`NameBadge.Application`): `PowerMonitor`, `EInk`, `Display`, `TaskSupervisor`, `Spotify.{Tokens, Library, ArtCache, Screen}`, `Button`. Everything is device-only: the app no longer builds for `MIX_TARGET=host`.

See `docs/` for per-layer paper documentation. **Note**: `docs/elixir_application.md` describes the old multi-screen app and no longer reflects the code.

## Git Remotes

- `origin` → `git@github.com:markomitranic/name_badge.git` — this is Marko's personal fork. **Push directly to `origin/main`**; this is not a shared project and there is no PR review flow. Feel free to commit and push without asking once the work is done and verified.
- `upstream` → `https://github.com/protolux-electronics/name_badge.git` — original; read-only in practice, no interest in upstreaming changes.

Pull upstream updates with `git fetch upstream && git merge upstream/main` (or rebase) — only if you explicitly want something from upstream.

## Documentation (`docs/`)

AI-consumable paper documentation extracted from the four upstream repos. Each file opens with its own Markdown table of contents.

- [`docs/bootloader_uboot.md`](./docs/bootloader_uboot.md)
  - Represents the second-stage bootloader (U-Boot 2025.04 + SPL) that runs after the SoC's BROM and hands control to the Linux kernel, plus the eMMC partition layout and how the device picks between the A and B firmware slots.
  - Tags: low-level, hardware, bootloader, u-boot, spl, boot-sequence, partitions, a-b-slots, firmware-selection, emmc, fel-boundary, brick-risk
- [`docs/device_tree_kernel.md`](./docs/device_tree_kernel.md)
  - Represents the Linux 6.12.32 kernel configuration, backported PWM patches, and the `sun8i-t113s-trellis.dts` device tree that describes every GPIO pin, SPI bus, and peripheral on the badge.
  - Tags: low-level, hardware, kernel, linux, device-tree, gpio, spi, uart, mmc, peripherals, drivers, wifi-driver, regulators, pinout
- [`docs/nerves_system_trellis.md`](./docs/nerves_system_trellis.md)
  - Represents the Nerves system package (Buildroot-based Linux distribution) that glues kernel + U-Boot + rootfs overlay + fwup together into the platform layer the Elixir app runs on.
  - Tags: low-level, platform, nerves-system, buildroot, linux-distribution, rootfs, erlinit, fwup, ota, toolchain, cross-compile, versioning, hex-package
- [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md)
  - Represents the FEL recovery toolkit (`launch.sh` + custom U-Boot + UMS gadget) used for first-time flashing or recovering a bricked badge over USB-C.
  - Tags: low-level, hardware, flash, brick, recovery, fel, sunxi-tools, usb, u-boot-ums, mix-burn, macos-gotchas, emergency
- [`docs/elixir_application.md`](./docs/elixir_application.md)
  - Represents the `name_badge` Elixir/Nerves application (this repo) plus a runbook of day-to-day operations, flashing, SSH/IEx commands, and recovery recipes.
  - Tags: high-level, application, elixir, nerves, screens, typst, dither, eink-rendering, vintagenet, nerveshub, config, simulator, runbook, development, daily-ops

## Hardware Quick Reference

- Board: **Trellis** (prototype name: "Wisteria"), Allwinner T113-S4 SoC (sun8i-r528 variant).
- Display: 400×300 1-bit e-ink (the FPS bottleneck, not the CPU).
- Connectivity: USB-C (power + data + SSH) and onboard Wi-Fi (Realtek, 2.4 GHz only).
- SSH hostname: `wisteria.local` (mDNS works over USB on macOS).
- Default credentials: username `nerves`, password `nerves`.

## Required Environment Variables

`mise.toml` pins `MIX_TARGET=trellis`. Secrets live in `.mise.local.toml` (git-ignored):

```toml
[env]
# Spotify (see scripts/spotify_auth.exs to obtain). All three are required,
# or the badge shows a "not configured" page.
SPOTIFY_CLIENT_ID = "..."
SPOTIFY_CLIENT_SECRET = "..."
SPOTIFY_REFRESH_TOKEN = "..."
# Optional, first-boot WiFi baked into the burn:
# NERVES_WIFI_SSID = "..."
# NERVES_WIFI_PASSPHRASE = "..."
```

The Spotify values are compiled into the firmware. If the local file is lost, they can be read back off a running badge: `Application.get_env(:name_badge, :spotify)` over SSH.

Wi-Fi credentials are set at runtime on the device via `VintageNetWiFi.quick_configure/2` (persists across reboots), so baking them into firmware is usually unnecessary. With no WiFi wizard any more, that SSH command (over the USB cable if needed) is the only way to change networks.

## Common Commands

```sh
# First-time build
mix deps.get
mix firmware

# Flash over USB to a badge in FEL / mass-storage mode
mix burn

# Flash over SSH to a running badge (password: nerves)
cat _build/trellis_dev/nerves/images/name_badge.fw | ssh -s nerves@wisteria.local fwup

# Or generate a reusable upload script
MIX_TARGET=trellis mix firmware.gen.script
./upload.sh wisteria.local

# SSH into the badge (IEx prompt, password: nerves)
ssh nerves@wisteria.local
```

> [!NOTE]
> The `mix firmware` success message suggests `mix upload` — **that task does not exist in this project**. Use the pipe or `upload.sh`. Running `mix upload` fails with "The task 'upload' could not be found".

Inside IEx on the badge:

```elixir
VintageNet.info()                                   # network status
VintageNetWiFi.quick_configure("ssid", "password")  # set WiFi at runtime (persists)
NervesTime.restart_ntpd()                           # fix clock / TLS errors
NameBadge.Battery.voltage()                         # e.g. 3.82 (> 4.5 on USB)
NameBadge.Battery.percentage()                      # 0-100 along the measured curve
```

## Toolchain Prerequisites (macOS)

1. Elixir + Erlang via `mise` (run `mise install`). `mise.toml` pins Elixir 1.19.5 / Erlang 28.3.
2. Nerves bootstrap archive (one-time, user-scoped):
   ```sh
   mix local.hex --force
   mix local.rebar --force
   mix archive.install hex nerves_bootstrap --force
   ```
3. Nerves build prereqs — all are required (`pkg-config` for `vintage_net_wifi`'s native build, `coreutils` for `gstat` in `mix firmware`):
   ```sh
   brew install xz fwup squashfs pkg-config coreutils
   ```
4. `sunxi-tools` for FEL / USB recovery flashing only — prefer the HEAD build:
   ```sh
   brew install --build-from-source --head lukad/sunxi-tools-tap/sunxi-tools
   ```
5. `sshpass` (optional, only if automating flash/ssh without typing passwords):
   ```sh
   brew install hudochenkov/sshpass/sshpass
   ```

Rust is no longer required (typst NIF ships pre-compiled).

## FEL Recovery Flash Flow

For first-time flashing or brick recovery. Full procedure in [`docs/usb_fel_loaders.md`](./docs/usb_fel_loaders.md).

```sh
# 1. Power off badge → hold FEL button → power on → release.
# 2. Clone usb_fel_loaders (or run from a fresh copy):
git clone https://github.com/gworkman/usb_fel_loaders && cd usb_fel_loaders
./launch.sh trellis                                # auto-downloads trellis.bin
# 3. From this repo:
MIX_TARGET=trellis mix burn
```

If `usb_bulk_send() ERROR -1` appears: let the badge sit in FEL for a few seconds, try a known-good USB-C **data** cable, or `brew reinstall libusb`.

## Spotify Album Art Screen

Port of [MusaicFM](https://github.com/obrhoff/MusaicFM): rotates through the user's Spotify *saved albums* library, one cover at a time, cassette-tape spine layout (300×300 art on the left, vertical separator, artist + album rotated 90° up the right side). Swaps album every 5 minutes; button A forces an immediate new album.

**One-time setup** (on the laptop):

1. Register a Spotify app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard). Add redirect URI `http://127.0.0.1:8888/callback`. Copy the **Client ID** and **Client Secret**.
2. Obtain a refresh token:
   ```sh
   SPOTIFY_CLIENT_ID=... SPOTIFY_CLIENT_SECRET=... elixir scripts/spotify_auth.exs
   ```
   Browser opens → log in to Spotify → script prints the three env vars.
3. Paste them into `.mise.local.toml` under `[env]`, then reflash (`./scripts/build.sh && ./scripts/push.sh`).

**Runtime files** on the badge (`/data/`):

- `/data/spotify_tokens.json`: holds any refresh token Spotify rotates (survives reboot; falls back to the env-var value on wipe).
- `/data/spotify_library.json`: cached library size (refreshed every 24 h on the next fetch).
- `/data/spotify_art/`: queue of prefetched, pre-dithered covers (`<id>.png` + `<id>.json` pairs). Refilled in batches of 10 when it drops below 3, so rotation never blocks on the network. When it's empty the last cover stays up and the screen retries every 30 s.

**Modules**: `NameBadge.Spotify.{Tokens, HTTP, Library, Album, Art, ArtCache, Screen}`. `Spotify.Screen` is a plain GenServer: it takes a cover, composes the spine with Typst, and draws it through `Display`. `NameBadge.Button` sends it `:button_pressed` on the falling edge of BTN_1; presses that queue up during a draw are dropped.

**Boot**: no splash. The panel keeps its last image without power, so the previous cover stays up until the first new one is drawn (a cache hit at boot draws within seconds).

**Spine extras**: text falls back per-glyph from Poppins to the bundled `Noto Sans JP` for Japanese titles. Only the font weights the spine uses (Poppins Regular/Bold/SemiBold Italic + Noto Sans JP) ship in `priv/typst/fonts`. The `anti_ghost: true` draw opt (a white flush before the draw, handled in `NameBadge.Display`) is **off**: the double refresh was more annoying than the ghosting. It's one keyword away in `@draw_opts` in `Spotify.Screen` if residue reappears.

**Grayscale**: the screen renders in 4-level grayscale (`mode: :grayscale`, art dithered at `bit_depth: 2`). The hand-calibrated UC8276 register waveform lives in the `eink` dep (Marko's fork, branch `grayscale-on-dp`); swap `mix.exs` back to hex once upstream ships a real grayscale LUT. The calibration harness (`NameBadge.GrayTune`, `scripts/gray_calibration.html`) was removed; recover it from git history if the LUT ever needs re-tuning.

## Power Management

The WiFi chip is the biggest battery drain and can be hard-powered-off via the `WIFI_EN` GPIO: `NameBadge.Wifi.power_off/1` drives the pin when VintageNet deconfigures `wlan0`. The policy is deliberately dumb, no scheduler:

- **On battery, WiFi is off except during refill bursts.** VintageNet powers it up at boot from the persisted config; the screen's first `ArtCache.take/0` powers it straight back down. Each refill burst (~20 s, every ~35-50 min of rotation) turns it on, fetches up to 10 covers, and turns it off again however the burst ended.
- **Low battery (< 3.65 V, ~35%) skips refills**: `Battery.low?/0` gates the refill, so covers rotate from the cache and then the last one stays up. The chip's power-on surge browned the board out mid-refill at 3.56 V (survived at 3.57 V). This was also the cause of the "unresolved" July 2026 hard reset during a battery drain test.
- **On USB power WiFi never turns off**: `Network.wifi_off/0` refuses while `Battery.charging?()` (> 4.5 V, the ADC reads the input rail), and `NameBadge.PowerMonitor` re-powers the chip within 10 s of plugging in. USB power never reads low.
- **`Battery` is stateless**: every call is one sysfs ADC read, no polling process (the old one woke the CPU twice a second and could be starved into call timeouts).
- **Battery percentage follows a measured discharge curve** (`Battery.percentage_at/1`): two full WiFi-on drains, 6-7 h each from full to dead at ~3.35 V. 3.55 V is ~10% (~40 min left with WiFi on). Nothing on the badge displays it; check over SSH.
- **The red status LED is silenced at boot** (`silence_status_led/0` in `Application`); the kernel otherwise blinks it 24/7 (~0.5 mA average). Re-enable at runtime: `File.write!("/sys/class/leds/red:status/trigger", "heartbeat")`.

## Monitoring (off by default)

`NameBadge.Diagnostics` holds three recorders, each enabled by uncommenting one line in `NameBadge.Application`:

- `Diagnostics.attach_disk_logger()`: warning+ logs and crash reports to `/data/debug.log` (2×512 KB). RingLogger is RAM-only and loses everything on reboot.
- `Diagnostics.log_boot()`: a `ts,boot,voltage,wifi` line per boot in `/data/power.log`. A boot with no graceful `/data/shutdown.txt` means a hard reset (watchdog, brownout, power cut).
- `NameBadge.Diagnostics` child: minute health samples (load, memory, scheduler queues, key process mailboxes, voltage, wifi state) to `/data/health.jsonl` (2×2 MB) plus the last two boots' `dmesg`. `Diagnostics.measure/2` already wraps display draws, cover download/dither/compose and art refills; while the recorder is off those calls cost a dropped cast.

## Gotchas Worth Remembering

- **WiFi is off on battery** (except during refill bursts). To SSH in: plug in USB power (WiFi comes back within ~10 s) or use the USB cable directly (SSH over `usb0` works regardless of WiFi).
- **BEAM monotonic time is negative** (starts around −576×10⁹ ms). Never compare `System.monotonic_time/1` against a literal `0` deadline: it reads as "deadline passed 18 years from now". This exact bug silently disabled ArtCache refills once already.
- **Never leave a `GenServer.call` on the render path at its 5 s default.** The board has two cores and the art refill saturates both: a grayscale draw measured 1.3 s idle and 4.0 s under dither load. A blown timeout used to crash the screen into a reset loop. `Display` (30 s draw / 60 s render) and `ArtCache` (30 s) carry explicit timeouts. `EInk.draw/2` and `EInk.clear/2` hardcode the 5 s default, so `Display` calls that GenServer directly.
- **Typst templates use Elixir interpolation `#{var}`, not EEx.** A leading `#` on the first Typst line crashes the renderer.
- **`mix upload` is NOT a task in this project**: use `./scripts/push.sh`.
- **Clock drift after boot** causes TLS "Certificate Expired" errors. They self-heal via NTP; force with `NervesTime.restart_ntpd()`.
- **After reflash**, run `ssh-keygen -R wisteria.local` to clear the stale host key.
- **Post-fwup reboot takes 2–3 minutes**, not 30–60 s. Ping comes back first, then SSH once BEAM is up.
- **Keep the badge on USB-C power during OTA updates.**
- **WiFi chip is 2.4 GHz only** (Realtek RTL8188FU, visible in dmesg). Dual-band SSIDs fine; 5 GHz-only SSIDs won't connect.
- **Check connection state, not just "associated"**: `VintageNet.get(["interface","wlan0","connection"])` → `:disconnected | :lan | :internet`.
- **`mix` on PATH is a mise shim, and mise's config env wins over yours.** A `MIX_TARGET` in any mise config silently overrides an `export`. Go through `mise exec -- env MIX_TARGET=trellis mix ...` (what `scripts/build.sh` and `scripts/burn.sh` do).
- **WiFi power-on glitches the storage bus**: 162 of 163 logged `sunxi-mmc 4020000.mmc: data error` lines landed within 5 s of a WiFi power-on (the chip and eMMC likely share the 3.3 V rail). The kernel retries; across two months of logs no write was ever lost and ext4's error count is 0. Worth watching, not handling.

## When Answering Hardware / Firmware Questions

Order of authority (most fresh → least):

1. **This repository** — code, `mix.exs`, `config/`, `lib/`, `priv/typst/`. Ground truth for the app layer.
2. **`docs/`** — per-layer paper documentation. Captures everything that used to live in the sibling clones. Runbook lives in `elixir_application.md`.
3. **Upstream repos on GitHub** — re-clone temporarily if you need source-level access beyond what `docs/` captures:
   - `protolux-electronics/name_badge` (upstream of this fork)
   - `protolux-electronics/nerves_system_trellis` (consumed as hex package)
   - `gworkman/usb_fel_loaders` (FEL recovery toolkit)
4. **General Nerves/Elixir knowledge** — fall back when the above don't cover the case.
